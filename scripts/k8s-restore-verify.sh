#!/usr/bin/env sh
set -eu

NAMESPACE="${NAMESPACE:-swiftpay-dev}"
POD_NAME="${POD_NAME:-swiftpay-restore-verify}"
REDIS_PVC="${REDIS_PVC:-redis-pvc}"
IMAGE="${IMAGE:-postgres:16-alpine}"
POSTGRES_SECRET="${POSTGRES_SECRET:-db-secrets}"
PGHOST_VALUE="${PGHOST_VALUE:-postgres}"
PGPORT_VALUE="${PGPORT_VALUE:-5432}"
APP_CONFIG="${APP_CONFIG:-app-config}"

kubectl rollout status statefulset/postgres -n "${NAMESPACE}" --timeout=300s >/dev/null
kubectl rollout status deployment/redis -n "${NAMESPACE}" --timeout=300s >/dev/null
kubectl rollout status deployment/rabbitmq -n "${NAMESPACE}" --timeout=300s >/dev/null
kubectl rollout status deployment/api-gateway -n "${NAMESPACE}" --timeout=300s >/dev/null
kubectl rollout status deployment/auth-service -n "${NAMESPACE}" --timeout=300s >/dev/null
kubectl rollout status deployment/wallet-service -n "${NAMESPACE}" --timeout=300s >/dev/null
kubectl rollout status deployment/transaction-service -n "${NAMESPACE}" --timeout=300s >/dev/null
kubectl rollout status deployment/notification-service -n "${NAMESPACE}" --timeout=300s >/dev/null
kubectl rollout status deployment/frontend -n "${NAMESPACE}" --timeout=300s >/dev/null

if ! kubectl get pvc -n "${NAMESPACE}" "${REDIS_PVC}" >/dev/null 2>&1; then
  echo "ERROR: PVC ${REDIS_PVC} not found in namespace ${NAMESPACE}" >&2
  exit 1
fi

kubectl delete pod -n "${NAMESPACE}" "${POD_NAME}" --ignore-not-found >/dev/null 2>&1 || true
trap 'kubectl delete pod -n "${NAMESPACE}" "${POD_NAME}" --ignore-not-found >/dev/null 2>&1 || true' EXIT

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NAMESPACE}
  labels:
    backup-role: state-backup
spec:
  restartPolicy: Never
  containers:
    - name: verify
      image: ${IMAGE}
      imagePullPolicy: IfNotPresent
      resources:
        requests:
          cpu: 25m
          memory: 64Mi
        limits:
          cpu: 150m
          memory: 128Mi
      env:
        - name: PGHOST
          value: ${PGHOST_VALUE}
        - name: PGPORT
          value: "${PGPORT_VALUE}"
        - name: PGUSER
          valueFrom:
            secretKeyRef:
              name: ${POSTGRES_SECRET}
              key: DB_USER
        - name: PGPASSWORD
          valueFrom:
            secretKeyRef:
              name: ${POSTGRES_SECRET}
              key: DB_PASSWORD
        - name: PGDATABASE
          valueFrom:
            configMapKeyRef:
              name: ${APP_CONFIG}
              key: DB_NAME
      command:
        - /bin/sh
        - -ec
        - |
          echo "Waiting for PostgreSQL at \${PGHOST}:\${PGPORT}"
          for _ in \$(seq 1 60); do
            if pg_isready -h "\${PGHOST}" -p "\${PGPORT}" -U "\${PGUSER}" -d "\${PGDATABASE}" >/dev/null 2>&1; then
              break
            fi
            sleep 2
          done

          echo "Verifying PostgreSQL restore state"
          psql -h "\${PGHOST}" -p "\${PGPORT}" -U "\${PGUSER}" -d "\${PGDATABASE}" -v ON_ERROR_STOP=1 -c "
            SELECT tablename
            FROM pg_tables
            WHERE schemaname = 'public'
              AND tablename IN ('users', 'wallets', 'transactions', 'notifications', 'refresh_tokens', 'user_sessions')
            ORDER BY tablename;
          "

          psql -h "\${PGHOST}" -p "\${PGPORT}" -U "\${PGUSER}" -d "\${PGDATABASE}" -v ON_ERROR_STOP=1 -c "
            SELECT
              (SELECT COUNT(*) FROM users) AS users,
              (SELECT COUNT(*) FROM wallets) AS wallets,
              (SELECT COUNT(*) FROM transactions) AS transactions;
          "

          echo "Verifying Redis PVC data files"
          if [ ! -f /redis-data/dump.rdb ]; then
            echo "ERROR: Redis dump.rdb not present on restored PVC" >&2
            exit 1
          fi
          find /redis-data -maxdepth 2 -type f | sort
      volumeMounts:
        - name: redis-storage
          mountPath: /redis-data
  volumes:
    - name: redis-storage
      persistentVolumeClaim:
        claimName: ${REDIS_PVC}
EOF

for _ in $(seq 1 180); do
  phase="$(kubectl get pod -n "${NAMESPACE}" "${POD_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [ "${phase}" = "Succeeded" ] || [ "${phase}" = "Failed" ]; then
    break
  fi
  sleep 1
done

kubectl logs -n "${NAMESPACE}" "${POD_NAME}"
phase="$(kubectl get pod -n "${NAMESPACE}" "${POD_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
if [ "${phase}" != "Succeeded" ]; then
  echo "ERROR: restore verification pod ended in phase ${phase:-Unknown}" >&2
  exit 1
fi
