#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/k8s-restore-run.sh
  ./scripts/k8s-restore-run.sh <postgres-backup.dump> <redis-backup.rdb>
  ./scripts/k8s-restore-run.sh --help

Behavior:
  With no arguments, restore the newest valid PostgreSQL and Redis backups.
  With two arguments, restore the specific backup pair you name.
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

if [[ "$#" -ne 0 && "$#" -ne 2 ]]; then
  echo "ERROR: expected either zero arguments or exactly two backup filenames" >&2
  usage >&2
  exit 1
fi

NAMESPACE="${NAMESPACE:-swiftpay-dev}"
POD_NAME="${POD_NAME:-swiftpay-state-restore}"
BACKUP_PVC="${BACKUP_PVC:-swiftpay-backup-storage}"
REDIS_PVC="${REDIS_PVC:-redis-pvc}"
IMAGE="${IMAGE:-postgres:16-alpine}"
POSTGRES_SECRET="${POSTGRES_SECRET:-db-secrets}"
PGHOST_VALUE="${PGHOST_VALUE:-postgres}"
PGPORT_VALUE="${PGPORT_VALUE:-5432}"
APP_CONFIG="${APP_CONFIG:-app-config}"
POSTGRES_STATEFULSET="${POSTGRES_STATEFULSET:-postgres}"
REDIS_DEPLOYMENT="${REDIS_DEPLOYMENT:-redis}"
RABBITMQ_DEPLOYMENT="${RABBITMQ_DEPLOYMENT:-rabbitmq}"
POSTGRES_BACKUP_FILE="${1:-}"
REDIS_BACKUP_FILE="${2:-}"

APP_DEPLOYMENTS=(
  api-gateway
  auth-service
  frontend
  notification-service
  transaction-service
  wallet-service
  rabbitmq
  redis
)

ORIGINAL_REPLICAS=()

if ! kubectl get pvc -n "${NAMESPACE}" "${BACKUP_PVC}" >/dev/null 2>&1; then
  echo "ERROR: PVC ${BACKUP_PVC} not found in namespace ${NAMESPACE}" >&2
  exit 1
fi

if ! kubectl get pvc -n "${NAMESPACE}" "${REDIS_PVC}" >/dev/null 2>&1; then
  echo "ERROR: PVC ${REDIS_PVC} not found in namespace ${NAMESPACE}" >&2
  exit 1
fi

for deployment in "${APP_DEPLOYMENTS[@]}"; do
  ORIGINAL_REPLICAS+=("$(kubectl get deployment -n "${NAMESPACE}" "${deployment}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)")
done

restore_workloads() {
  local index
  local deployment
  local replicas

  for index in "${!APP_DEPLOYMENTS[@]}"; do
    deployment="${APP_DEPLOYMENTS[$index]}"
    replicas="${ORIGINAL_REPLICAS[$index]}"
    kubectl scale deployment -n "${NAMESPACE}" "${deployment}" --replicas="${replicas}" >/dev/null 2>&1 || true
  done

  if [[ "${ORIGINAL_REPLICAS[7]}" -gt 0 ]]; then
    kubectl rollout status deployment/"${REDIS_DEPLOYMENT}" -n "${NAMESPACE}" --timeout=300s >/dev/null 2>&1 || true
  fi
  if [[ "${ORIGINAL_REPLICAS[6]}" -gt 0 ]]; then
    kubectl rollout status deployment/"${RABBITMQ_DEPLOYMENT}" -n "${NAMESPACE}" --timeout=300s >/dev/null 2>&1 || true
  fi
  for index in 0 1 5 4 3 2; do
    deployment="${APP_DEPLOYMENTS[$index]}"
    replicas="${ORIGINAL_REPLICAS[$index]}"
    if [[ "${replicas}" -gt 0 ]]; then
      kubectl rollout status deployment/"${deployment}" -n "${NAMESPACE}" --timeout=300s >/dev/null 2>&1 || true
    fi
  done
}

wait_for_zero_pods() {
  local namespace="$1"
  local selector="$2"
  for _ in $(seq 1 180); do
    local count
    count="$(kubectl get pods -n "${namespace}" -l "${selector}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${count}" = "0" ]]; then
      return 0
    fi
    sleep 1
  done
  echo "ERROR: Timed out waiting for pods with selector ${selector} to terminate" >&2
  return 1
}

trap 'restore_workloads; kubectl delete pod -n "${NAMESPACE}" "${POD_NAME}" --ignore-not-found >/dev/null 2>&1 || true' EXIT

for deployment in "${APP_DEPLOYMENTS[@]}"; do
  kubectl scale deployment -n "${NAMESPACE}" "${deployment}" --replicas=0 >/dev/null
done

wait_for_zero_pods "${NAMESPACE}" "app=api-gateway"
wait_for_zero_pods "${NAMESPACE}" "app=auth-service"
wait_for_zero_pods "${NAMESPACE}" "app=frontend"
wait_for_zero_pods "${NAMESPACE}" "app=notification-service"
wait_for_zero_pods "${NAMESPACE}" "app=transaction-service"
wait_for_zero_pods "${NAMESPACE}" "app=wallet-service"
wait_for_zero_pods "${NAMESPACE}" "app=rabbitmq"
wait_for_zero_pods "${NAMESPACE}" "app=redis"

kubectl delete pod -n "${NAMESPACE}" "${POD_NAME}" --ignore-not-found >/dev/null 2>&1 || true

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
    - name: restore
      image: ${IMAGE}
      imagePullPolicy: IfNotPresent
      resources:
        requests:
          cpu: 50m
          memory: 128Mi
        limits:
          cpu: 250m
          memory: 256Mi
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
        - name: POSTGRES_BACKUP_FILE
          value: "${POSTGRES_BACKUP_FILE}"
        - name: REDIS_BACKUP_FILE
          value: "${REDIS_BACKUP_FILE}"
      command:
        - /bin/sh
        - -ec
        - |
          postgres_backup="\${POSTGRES_BACKUP_FILE}"
          redis_backup="\${REDIS_BACKUP_FILE}"

          if [ -z "\${postgres_backup}" ]; then
            postgres_backup="\$(find /backup -maxdepth 1 -type f -name 'swiftpay-postgres-*.dump' -size +0c 2>/dev/null | sort | tail -n 1)"
          elif [ "\${postgres_backup#/}" = "\${postgres_backup}" ]; then
            postgres_backup="/backup/\${postgres_backup}"
          fi

          if [ -z "\${redis_backup}" ]; then
            redis_backup="\$(find /backup -maxdepth 1 -type f -name 'swiftpay-redis-*.rdb' -size +0c 2>/dev/null | sort | tail -n 1)"
          elif [ "\${redis_backup#/}" = "\${redis_backup}" ]; then
            redis_backup="/backup/\${redis_backup}"
          fi

          if [ -z "\${postgres_backup}" ] || [ ! -f "\${postgres_backup}" ]; then
            echo "ERROR: PostgreSQL backup file not found: \${postgres_backup:-<none>}" >&2
            exit 1
          fi

          if [ -z "\${redis_backup}" ] || [ ! -f "\${redis_backup}" ]; then
            echo "ERROR: Redis backup file not found: \${redis_backup:-<none>}" >&2
            exit 1
          fi

          echo "Waiting for PostgreSQL at \${PGHOST}:\${PGPORT}"
          for _ in \$(seq 1 60); do
            if pg_isready -h "\${PGHOST}" -p "\${PGPORT}" -U "\${PGUSER}" -d "\${PGDATABASE}" >/dev/null 2>&1; then
              break
            fi
            sleep 2
          done

          pg_restore \
            --host="\${PGHOST}" \
            --port="\${PGPORT}" \
            --username="\${PGUSER}" \
            --dbname="\${PGDATABASE}" \
            --clean \
            --if-exists \
            --no-owner \
            --no-privileges \
            --exit-on-error \
            "\${postgres_backup}"

          rm -rf /redis-data/* /redis-data/.[!.]* /redis-data/..?* 2>/dev/null || true
          cp "\${redis_backup}" /redis-data/dump.rdb
          rm -rf /redis-data/appendonlydir 2>/dev/null || true

          echo "Restore completed from \${postgres_backup} and \${redis_backup}"
      volumeMounts:
        - name: backup-storage
          mountPath: /backup
        - name: redis-storage
          mountPath: /redis-data
  volumes:
    - name: backup-storage
      persistentVolumeClaim:
        claimName: ${BACKUP_PVC}
    - name: redis-storage
      persistentVolumeClaim:
        claimName: ${REDIS_PVC}
EOF

for _ in $(seq 1 60); do
  if kubectl get pod -n "${NAMESPACE}" "${POD_NAME}" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! kubectl get pod -n "${NAMESPACE}" "${POD_NAME}" >/dev/null 2>&1; then
  echo "ERROR: restore pod ${POD_NAME} was not created" >&2
  exit 1
fi

seen_pod=0
for _ in $(seq 1 600); do
  phase="$(kubectl get pod -n "${NAMESPACE}" "${POD_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ -n "${phase}" ]]; then
    seen_pod=1
  fi
  if [[ "${phase}" = "Succeeded" || "${phase}" = "Failed" ]]; then
    break
  fi
  if [[ "${seen_pod}" = "1" && -z "${phase}" ]]; then
    echo "ERROR: restore pod ${POD_NAME} disappeared before reaching a terminal phase" >&2
    exit 1
  fi
  sleep 1
done

kubectl logs -n "${NAMESPACE}" "${POD_NAME}"
phase="$(kubectl get pod -n "${NAMESPACE}" "${POD_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
if [[ "${phase}" != "Succeeded" ]]; then
  echo "ERROR: restore pod ended in phase ${phase:-Unknown}" >&2
  exit 1
fi
