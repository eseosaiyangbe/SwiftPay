#!/usr/bin/env sh
set -eu

NAMESPACE="${NAMESPACE:-swiftpay-dev}"
POD_NAME="${POD_NAME:-swiftpay-backup-inspect}"
PVC_NAME="${PVC_NAME:-swiftpay-backup-storage}"
IMAGE="${IMAGE:-busybox:1.36}"

if ! kubectl get pvc -n "${NAMESPACE}" "${PVC_NAME}" >/dev/null 2>&1; then
  echo "ERROR: PVC ${PVC_NAME} not found in namespace ${NAMESPACE}" >&2
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
spec:
  restartPolicy: Never
  containers:
    - name: inspect
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
          ls -lh /backup
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
  if [ "${phase}" = "Succeeded" ] || [ "${phase}" = "Failed" ] || [ "${phase}" = "Running" ]; then
    break
  fi
  sleep 1
done

kubectl logs -n "${NAMESPACE}" "${POD_NAME}"
