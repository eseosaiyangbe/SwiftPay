#!/usr/bin/env bash
set -euo pipefail

THRESHOLD_MB="${DOCKER_LOG_WARN_MB:-200}"
TOP_N="${DOCKER_LOG_TOP_N:-10}"
HELPER_IMAGE="${DOCKER_STORAGE_HELPER_IMAGE:-alpine:3.20}"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi

echo "SwiftPay Docker storage check"
echo "Threshold: ${THRESHOLD_MB}MB"
echo

echo "== Docker system summary =="
docker system df
echo

echo "== SwiftPay container logging policy =="
docker ps -a \
  --filter "name=swiftpay-" \
  --format '{{.Names}}' \
  | while IFS= read -r name; do
      [ -n "${name}" ] || continue
      docker inspect "${name}" --format '{{.Name}}|{{.HostConfig.LogConfig.Type}}|{{index .HostConfig.LogConfig.Config "max-size"}}|{{index .HostConfig.LogConfig.Config "max-file"}}'
    done \
  | sed 's#^/##' \
  | sort \
  | awk -F'|' '
      BEGIN {
        printf "%-32s %-12s %-10s %-10s %-8s\n", "CONTAINER", "DRIVER", "MAX-SIZE", "MAX-FILE", "STATUS"
      }
      {
        status = "ok"
        if ($2 == "json-file" && ($3 == "" || $4 == "")) {
          status = "unbounded"
        } else if ($2 == "") {
          status = "unknown"
        }
        printf "%-32s %-12s %-10s %-10s %-8s\n", $1, ($2 == "" ? "-" : $2), ($3 == "" ? "-" : $3), ($4 == "" ? "-" : $4), status
      }
    '
echo

echo "== Top Docker json-file logs =="
inspect_payload="$(
  docker ps -a --format '{{.Names}}' \
    | while IFS= read -r name; do
        [ -n "${name}" ] || continue
        docker inspect "${name}" --format '{{.Name}}|{{.LogPath}}'
      done \
    | sed 's#^/##'
)"

if [ -z "${inspect_payload}" ]; then
  echo "No containers found."
  exit 0
fi

top_logs="$(
  docker run \
    --rm \
    -e INSPECT_PAYLOAD="${inspect_payload}" \
    -i \
    -v /:/host:ro \
    "${HELPER_IMAGE}" \
    sh -s -- "${THRESHOLD_MB}" "${TOP_N}" <<'EOF'
threshold_mb="$1"
top_n="$2"

threshold_bytes=$((threshold_mb * 1024 * 1024))
tmpfile="$(mktemp)"

printf '%s\n' "${INSPECT_PAYLOAD}" | while IFS='|' read -r name log_path; do
  [ -n "${name}" ] || continue
  [ -n "${log_path}" ] || continue
  host_path="/host${log_path}"
  if [ -f "${host_path}" ]; then
    size_bytes="$(wc -c < "${host_path}" | tr -d ' ')"
    printf '%s|%s|%s\n' "${size_bytes}" "${name}" "${log_path}" >> "${tmpfile}"
  fi
done

if [ ! -s "${tmpfile}" ]; then
  rm -f "${tmpfile}"
  exit 0
fi

sort -t '|' -nr -k1,1 "${tmpfile}" | head -n "${top_n}" | while IFS='|' read -r size_bytes name log_path; do
  size_mb=$((size_bytes / 1024 / 1024))
  status="ok"
  if [ "${size_bytes}" -ge "${threshold_bytes}" ]; then
    status="warn"
  fi
  printf '%s|%s|%s|%s\n' "${size_mb}" "${status}" "${name}" "${log_path}"
done

rm -f "${tmpfile}"
EOF
)"

if [ -z "${top_logs}" ]; then
  echo "Could not inspect host log files from Docker helper container."
  echo "This usually means the local Docker runtime does not expose host log paths in a way this check can read."
  exit 0
fi

printf "%-10s %-8s %-32s %s\n" "SIZE_MB" "STATUS" "CONTAINER" "LOG_PATH"
printf '%s\n' "${top_logs}" | while IFS='|' read -r size_mb status name log_path; do
  printf "%-10s %-8s %-32s %s\n" "${size_mb}" "${status}" "${name}" "${log_path}"
done
echo

warn_count="$(printf '%s\n' "${top_logs}" | awk -F'|' '$2 == "warn" {count++} END {print count+0}')"
if [ "${warn_count}" -gt 0 ]; then
  echo "Warning: ${warn_count} Docker log file(s) exceeded ${THRESHOLD_MB}MB."
  echo "Investigate noisy containers before they push the runtime disk back into alerting."
else
  echo "No Docker log files exceeded ${THRESHOLD_MB}MB."
fi
