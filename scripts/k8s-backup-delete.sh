#!/usr/bin/env sh
set -eu

NAMESPACE="${NAMESPACE:-swiftpay-dev}"
POD_NAME="${POD_NAME:-swiftpay-backup-delete}"
PVC_NAME="${PVC_NAME:-swiftpay-backup-storage}"
IMAGE="${IMAGE:-busybox:1.36}"
MODE="${MODE:-all}"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/k8s-backup-delete.sh [--all]
  ./scripts/k8s-backup-delete.sh --keep-latest

Modes:
  --all
      Delete all backup artifacts from the backup PVC.

  --keep-latest
      Keep the newest PostgreSQL dump and newest Redis snapshot.
      Delete older backup artifacts only.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all)
      MODE="all"
      shift
      ;;
    --keep-latest)
      MODE="keep-latest"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! kubectl get pvc -n "${NAMESPACE}" "${PVC_NAME}" >/dev/null 2>&1; then
  echo "ERROR: PVC ${PVC_NAME} not found in namespace ${NAMESPACE}" >&2
  exit 1
fi

kubectl delete pod -n "${NAMESPACE}" "${POD_NAME}" --ignore-not-found >/dev/null 2>&1 || true
trap 'kubectl delete pod -n "${NAMESPACE}" "${POD_NAME}" --ignore-not-found >/dev/null 2>&1 || true' EXIT

case "${MODE}" in
  all)
    DELETE_SCRIPT='
      rm -f /backup/*
      ls -lh /backup
    '
    ;;
  keep-latest)
    DELETE_SCRIPT='
      latest_pg="$(find /backup -maxdepth 1 -type f -name "swiftpay-postgres-*.dump" -size +0c | sort | tail -n 1)"
      latest_redis="$(find /backup -maxdepth 1 -type f -name "swiftpay-redis-*.rdb" -size +0c | sort | tail -n 1)"

      for file in /backup/swiftpay-postgres-*.dump; do
        [ -e "$file" ] || continue
        [ "$file" = "$latest_pg" ] && continue
        rm -f "$file"
      done

      for file in /backup/swiftpay-redis-*.rdb; do
        [ -e "$file" ] || continue
        [ "$file" = "$latest_redis" ] && continue
        rm -f "$file"
      done

      ls -lh /backup
    '
    ;;
  *)
    echo "ERROR: unsupported mode ${MODE}" >&2
    exit 1
    ;;
esac

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  containers:
    - name: delete
      image: ${IMAGE}
      imagePullPolicy: IfNotPresent
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          cpu: 50m
          memory: 64Mi
      command:
        - sh
        - -ec
        - |
$(printf '%s\n' "${DELETE_SCRIPT}" | sed 's/^/          /')
      volumeMounts:
        - name: backup-storage
          mountPath: /backup
  volumes:
    - name: backup-storage
      persistentVolumeClaim:
        claimName: ${PVC_NAME}
EOF

for _ in $(seq 1 60); do
  phase="$(kubectl get pod -n "${NAMESPACE}" "${POD_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [ "${phase}" = "Succeeded" ] || [ "${phase}" = "Failed" ]; then
    break
  fi
  sleep 1
done

kubectl logs -n "${NAMESPACE}" "${POD_NAME}"
phase="$(kubectl get pod -n "${NAMESPACE}" "${POD_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
if [ "${phase}" != "Succeeded" ]; then
  echo "ERROR: delete pod ended in phase ${phase:-Unknown}" >&2
  exit 1
fi
