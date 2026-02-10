#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CLIENT_DIR="${REPO_ROOT}/rdma-http-demo/client"

if [[ ! -d "${CLIENT_DIR}" ]]; then
  echo "client directory not found: ${CLIENT_DIR}" >&2
  exit 1
fi

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need_cmd go
need_cmd timeout
need_cmd xargs

GO_TOOLCHAIN="${GOTOOLCHAIN:-go1.23.6}"
BIN_PATH="${BIN_PATH:-/tmp/rdma-http-demo-client}"
TIME_BIN="${TIME_BIN:-/usr/bin/time}"

ENDPOINT="${ENDPOINT:-http://10.0.1.2:18080}"
BUCKET="${BUCKET:-rdma-demo}"
KEY_PREFIX="${KEY_PREFIX:-stress}"
PAYLOAD_PREFIX="${PAYLOAD_PREFIX:-stress-payload}"
PUT_FILE="${PUT_FILE:-}"

REQUESTS="${REQUESTS:-200}"
CONCURRENCY="${CONCURRENCY:-16}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-20s}"
REQUEST_TIMEOUT_HARD="${REQUEST_TIMEOUT_HARD:-45s}"
ENSURE_BUCKET="${ENSURE_BUCKET:-false}"
STRESS_MODE="${STRESS_MODE:-single-process}"
INTER_REQUEST_SLEEP_MS="${INTER_REQUEST_SLEEP_MS:-0}"
RESTART_REMOTE_RELAY="${RESTART_REMOTE_RELAY:-false}"
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-$USER}"
REMOTE_RELAY_SERVICE="${REMOTE_RELAY_SERVICE:-rdma-http-relay}"

RDMA="${RDMA:-true}"
RDMA_DISABLE_FALLBACK="${RDMA_DISABLE_FALLBACK:-true}"
RDMA_FRAME_PAYLOAD="${RDMA_FRAME_PAYLOAD:-0}"
RDMA_SENDQ="${RDMA_SENDQ:-0}"
RDMA_RECVQ="${RDMA_RECVQ:-0}"
RDMA_INLINE="${RDMA_INLINE:-0}"
RDMA_OPEN_PARALLELISM="${RDMA_OPEN_PARALLELISM:-1}"
RDMA_OPEN_INTERVAL="${RDMA_OPEN_INTERVAL:-200ms}"

LOG_DIR="${LOG_DIR:-/tmp/rdma-stress-logs-$(date +%s)}"
mkdir -p "${LOG_DIR}"

AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-${MINIO_ROOT_USER:-minioadmin}}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-${MINIO_ROOT_PASSWORD:-minioadmin}}"
AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"

if [[ -z "${AWS_ACCESS_KEY_ID}" || -z "${AWS_SECRET_ACCESS_KEY}" ]]; then
  echo "missing credentials: set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY (or MINIO_ROOT_USER/MINIO_ROOT_PASSWORD)" >&2
  exit 1
fi
if [[ "${STRESS_MODE}" != "single-process" && "${STRESS_MODE}" != "multi-process" ]]; then
  echo "invalid STRESS_MODE=${STRESS_MODE}, expected single-process|multi-process" >&2
  exit 1
fi
if [[ "${RESTART_REMOTE_RELAY}" != "true" && "${RESTART_REMOTE_RELAY}" != "false" ]]; then
  echo "invalid RESTART_REMOTE_RELAY=${RESTART_REMOTE_RELAY}, expected true|false" >&2
  exit 1
fi

if [[ "${RESTART_REMOTE_RELAY}" == "true" ]]; then
  need_cmd ssh
fi

if [[ -n "${PUT_FILE}" && ! -f "${PUT_FILE}" ]]; then
  echo "invalid PUT_FILE=${PUT_FILE}, file not found" >&2
  exit 1
fi

put_body_args=(-payload "${PAYLOAD_PREFIX}")
warmup_body_args=(-payload "warmup")
payload_desc="inline:${#PAYLOAD_PREFIX}B"
if [[ -n "${PUT_FILE}" ]]; then
  payload_bytes="$(wc -c <"${PUT_FILE}" | tr -d " ")"
  put_body_args=(-put-file "${PUT_FILE}")
  warmup_body_args=(-put-file "${PUT_FILE}")
  payload_desc="file:${PUT_FILE}(${payload_bytes}B)"
fi

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

parse_endpoint_host() {
  local endpoint="$1"
  local no_scheme="${endpoint#*://}"
  local host_port="${no_scheme%%/*}"
  local host="${host_port}"

  if [[ "${host}" == \[*\]* ]]; then
    host="${host#[}"
    host="${host%]}"
  elif [[ "${host}" == *:* ]]; then
    host="${host%%:*}"
  fi

  echo "${host}"
}

restart_remote_relay() {
  local host="${REMOTE_HOST}"
  if [[ -z "${host}" ]]; then
    host="$(parse_endpoint_host "${ENDPOINT}")"
  fi
  if [[ -z "${host}" ]]; then
    echo "unable to resolve relay host from ENDPOINT=${ENDPOINT}; set REMOTE_HOST explicitly" >&2
    exit 1
  fi

  if [[ "${host}" == "127.0.0.1" || "${host}" == "localhost" ]]; then
    echo "RESTART_REMOTE_RELAY=true but endpoint host is local (${host}), skip remote restart"
    return 0
  fi

  echo "restarting ${REMOTE_RELAY_SERVICE} on ${REMOTE_USER}@${host}"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${REMOTE_USER}@${host}" \
    "sudo systemctl restart ${REMOTE_RELAY_SERVICE} && sleep 1 && systemctl is-active --quiet ${REMOTE_RELAY_SERVICE}"
}

echo "[1/4] building client binary with ${GO_TOOLCHAIN}"
(
  cd "${CLIENT_DIR}"
  GOTOOLCHAIN="${GO_TOOLCHAIN}" CGO_ENABLED=1 go build -tags rdma -o "${BIN_PATH}" .
)

if [[ "${RESTART_REMOTE_RELAY}" == "true" ]]; then
  echo "[2/4] restarting remote relay before stress run"
  restart_remote_relay
fi

if [[ "${STRESS_MODE}" == "multi-process" ]]; then
  if [[ "${ENSURE_BUCKET}" == "true" ]]; then
    echo "[2/4] ensuring bucket exists (${BUCKET})"
    timeout "${REQUEST_TIMEOUT_HARD}" "${BIN_PATH}" \
      -endpoint "${ENDPOINT}" \
      -mode put \
      -bucket "${BUCKET}" \
      -key "${KEY_PREFIX}-warmup.txt" \
      "${warmup_body_args[@]}" \
      -ensure-bucket=true \
      -count=1 \
      -concurrency=1 \
      -rdma="${RDMA}" \
      -rdma-disable-fallback="${RDMA_DISABLE_FALLBACK}" \
      -rdma-frame-payload="${RDMA_FRAME_PAYLOAD}" \
      -rdma-sendq="${RDMA_SENDQ}" \
      -rdma-recvq="${RDMA_RECVQ}" \
      -rdma-inline="${RDMA_INLINE}" \
      -rdma-open-parallelism="${RDMA_OPEN_PARALLELISM}" \
      -rdma-open-interval="${RDMA_OPEN_INTERVAL}" \
      -request-timeout="${REQUEST_TIMEOUT}" \
      >"${LOG_DIR}/warmup.log" 2>&1
  else
    echo "[2/4] warmup single put (ENSURE_BUCKET=false)"
    timeout "${REQUEST_TIMEOUT_HARD}" "${BIN_PATH}" \
      -endpoint "${ENDPOINT}" \
      -mode put \
      -bucket "${BUCKET}" \
      -key "${KEY_PREFIX}-warmup.txt" \
      "${warmup_body_args[@]}" \
      -ensure-bucket=false \
      -count=1 \
      -concurrency=1 \
      -rdma="${RDMA}" \
      -rdma-disable-fallback="${RDMA_DISABLE_FALLBACK}" \
      -rdma-frame-payload="${RDMA_FRAME_PAYLOAD}" \
      -rdma-sendq="${RDMA_SENDQ}" \
      -rdma-recvq="${RDMA_RECVQ}" \
      -rdma-inline="${RDMA_INLINE}" \
      -rdma-open-parallelism="${RDMA_OPEN_PARALLELISM}" \
      -rdma-open-interval="${RDMA_OPEN_INTERVAL}" \
      -request-timeout="${REQUEST_TIMEOUT}" \
      >"${LOG_DIR}/warmup.log" 2>&1
  fi
else
  echo "[2/4] single-process mode: skip separate warmup process"
fi

ok_file="$(mktemp)"
fail_file="$(mktemp)"
trap 'rm -f "${ok_file}" "${fail_file}"' EXIT

export BIN_PATH ENDPOINT BUCKET KEY_PREFIX PAYLOAD_PREFIX REQUESTS CONCURRENCY REQUEST_TIMEOUT REQUEST_TIMEOUT_HARD
export RDMA RDMA_DISABLE_FALLBACK RDMA_FRAME_PAYLOAD RDMA_SENDQ RDMA_RECVQ RDMA_INLINE
export RDMA_OPEN_PARALLELISM RDMA_OPEN_INTERVAL
export LOG_DIR ok_file fail_file INTER_REQUEST_SLEEP_MS PUT_FILE

request_time_log="${LOG_DIR}/request_phase.time"
rm -f "${request_time_log}"

start_ns="$(date +%s%N)"
if [[ "${STRESS_MODE}" == "single-process" ]]; then
  batch_log="${LOG_DIR}/batch.log"
  echo "[3/4] running stress requests=${REQUESTS} concurrency=${CONCURRENCY} (single-process)"
  set +e
  if [[ -x "${TIME_BIN}" ]]; then
    "${TIME_BIN}" -f "elapsed=%e user=%U sys=%S cpu_pct=%P rss_kb=%M" -o "${request_time_log}" \
      timeout "${REQUEST_TIMEOUT_HARD}" "${BIN_PATH}" \
      -endpoint "${ENDPOINT}" \
      -mode put \
      -bucket "${BUCKET}" \
      -key "${KEY_PREFIX}.txt" \
      "${put_body_args[@]}" \
      -ensure-bucket=false \
      -count="${REQUESTS}" \
      -concurrency="${CONCURRENCY}" \
      -rdma="${RDMA}" \
      -rdma-disable-fallback="${RDMA_DISABLE_FALLBACK}" \
      -rdma-frame-payload="${RDMA_FRAME_PAYLOAD}" \
      -rdma-sendq="${RDMA_SENDQ}" \
      -rdma-recvq="${RDMA_RECVQ}" \
      -rdma-inline="${RDMA_INLINE}" \
      -rdma-open-parallelism="${RDMA_OPEN_PARALLELISM}" \
      -rdma-open-interval="${RDMA_OPEN_INTERVAL}" \
      -request-timeout="${REQUEST_TIMEOUT}" \
      >"${batch_log}" 2>&1
  else
    timeout "${REQUEST_TIMEOUT_HARD}" "${BIN_PATH}" \
      -endpoint "${ENDPOINT}" \
      -mode put \
      -bucket "${BUCKET}" \
      -key "${KEY_PREFIX}.txt" \
      "${put_body_args[@]}" \
      -ensure-bucket=false \
      -count="${REQUESTS}" \
      -concurrency="${CONCURRENCY}" \
      -rdma="${RDMA}" \
      -rdma-disable-fallback="${RDMA_DISABLE_FALLBACK}" \
      -rdma-frame-payload="${RDMA_FRAME_PAYLOAD}" \
      -rdma-sendq="${RDMA_SENDQ}" \
      -rdma-recvq="${RDMA_RECVQ}" \
      -rdma-inline="${RDMA_INLINE}" \
      -rdma-open-parallelism="${RDMA_OPEN_PARALLELISM}" \
      -rdma-open-interval="${RDMA_OPEN_INTERVAL}" \
      -request-timeout="${REQUEST_TIMEOUT}" \
      >"${batch_log}" 2>&1
  fi
  batch_rc=$?
  set -e

  ok_count="$(grep -c "PutObject ok" "${batch_log}" || true)"
  if [[ "${ok_count}" -gt "${REQUESTS}" ]]; then
    ok_count="${REQUESTS}"
  fi
  fail_count="$((REQUESTS - ok_count))"
  if [[ "${batch_rc}" -eq 0 && "${fail_count}" -eq 0 ]]; then
    :
  elif [[ "${fail_count}" -eq 0 ]]; then
    fail_count=1
  fi
else
  echo "[3/4] running stress requests=${REQUESTS} concurrency=${CONCURRENCY} (multi-process)"
  set +e
  if [[ -x "${TIME_BIN}" ]]; then
    "${TIME_BIN}" -f "elapsed=%e user=%U sys=%S cpu_pct=%P rss_kb=%M" -o "${request_time_log}" \
      bash -c '
      seq 1 "${REQUESTS}" | xargs -P "${CONCURRENCY}" -I{} bash -c '"'"'
      idx="$1"
      key="${KEY_PREFIX}-${idx}.txt"
      log_file="${LOG_DIR}/req-${idx}.log"

      if [[ "${INTER_REQUEST_SLEEP_MS}" -gt 0 ]]; then
        stagger_ms=$(( ((idx - 1) % CONCURRENCY) * INTER_REQUEST_SLEEP_MS ))
        sleep "$(printf "%d.%03d" "$((stagger_ms/1000))" "$((stagger_ms%1000))")"
      fi

      put_args=(-payload "${PAYLOAD_PREFIX}-${idx}")
      if [[ -n "${PUT_FILE}" ]]; then
        put_args=(-put-file "${PUT_FILE}")
      fi

      if timeout "${REQUEST_TIMEOUT_HARD}" "${BIN_PATH}" \
        -endpoint "${ENDPOINT}" \
        -mode put \
        -bucket "${BUCKET}" \
        -key "${key}" \
        "${put_args[@]}" \
        -ensure-bucket=false \
        -count=1 \
        -concurrency=1 \
        -rdma="${RDMA}" \
        -rdma-disable-fallback="${RDMA_DISABLE_FALLBACK}" \
        -rdma-frame-payload="${RDMA_FRAME_PAYLOAD}" \
        -rdma-sendq="${RDMA_SENDQ}" \
        -rdma-recvq="${RDMA_RECVQ}" \
        -rdma-inline="${RDMA_INLINE}" \
        -rdma-open-parallelism="${RDMA_OPEN_PARALLELISM}" \
        -rdma-open-interval="${RDMA_OPEN_INTERVAL}" \
        -request-timeout="${REQUEST_TIMEOUT}" \
        >"${log_file}" 2>&1; then
        echo "${idx}" >>"${ok_file}"
      else
        echo "${idx}" >>"${fail_file}"
      fi
      '"'"' _ {}
      '
  else
    seq 1 "${REQUESTS}" | xargs -P "${CONCURRENCY}" -I{} bash -c '
    idx="$1"
    key="${KEY_PREFIX}-${idx}.txt"
    log_file="${LOG_DIR}/req-${idx}.log"

    if [[ "${INTER_REQUEST_SLEEP_MS}" -gt 0 ]]; then
      stagger_ms=$(( ((idx - 1) % CONCURRENCY) * INTER_REQUEST_SLEEP_MS ))
      sleep "$(printf "%d.%03d" "$((stagger_ms/1000))" "$((stagger_ms%1000))")"
    fi

    put_args=(-payload "${PAYLOAD_PREFIX}-${idx}")
    if [[ -n "${PUT_FILE}" ]]; then
      put_args=(-put-file "${PUT_FILE}")
    fi

    if timeout "${REQUEST_TIMEOUT_HARD}" "${BIN_PATH}" \
      -endpoint "${ENDPOINT}" \
      -mode put \
      -bucket "${BUCKET}" \
      -key "${key}" \
      "${put_args[@]}" \
      -ensure-bucket=false \
      -count=1 \
      -concurrency=1 \
      -rdma="${RDMA}" \
      -rdma-disable-fallback="${RDMA_DISABLE_FALLBACK}" \
      -rdma-frame-payload="${RDMA_FRAME_PAYLOAD}" \
      -rdma-sendq="${RDMA_SENDQ}" \
      -rdma-recvq="${RDMA_RECVQ}" \
      -rdma-inline="${RDMA_INLINE}" \
      -rdma-open-parallelism="${RDMA_OPEN_PARALLELISM}" \
      -rdma-open-interval="${RDMA_OPEN_INTERVAL}" \
      -request-timeout="${REQUEST_TIMEOUT}" \
      >"${log_file}" 2>&1; then
      echo "${idx}" >>"${ok_file}"
    else
      echo "${idx}" >>"${fail_file}"
    fi
  ' _ {}
  fi
  batch_rc=$?
  set -e

  ok_count="$(wc -l <"${ok_file}" | tr -d " ")"
  fail_count="$(wc -l <"${fail_file}" | tr -d " ")"
  if [[ "${batch_rc}" -ne 0 && "${fail_count}" -eq 0 ]]; then
    fail_count=1
  fi
fi

end_ns="$(date +%s%N)"
duration_ns="$((end_ns - start_ns))"

total_count="$((ok_count + fail_count))"

duration_sec="$(awk "BEGIN{printf \"%.3f\", ${duration_ns}/1000000000}")"
success_qps="$(awk "BEGIN{if (${duration_ns} > 0) printf \"%.2f\", ${ok_count}*1000000000/${duration_ns}; else print \"0.00\"}")"
success_ratio="$(awk "BEGIN{if (${total_count} > 0) printf \"%.2f\", ${ok_count}*100/${total_count}; else print \"0.00\"}")"

request_phase_elapsed_s="0"
request_phase_user_s="0"
request_phase_sys_s="0"
request_phase_cpu_pct="0"
request_phase_rss_kb="0"
if [[ -s "${request_time_log}" ]]; then
  request_phase_elapsed_s="$(awk '{for (i = 1; i <= NF; i++) { split($i, a, "="); if (a[1] == "elapsed") { print a[2] } }}' "${request_time_log}" | tail -n1)"
  request_phase_user_s="$(awk '{for (i = 1; i <= NF; i++) { split($i, a, "="); if (a[1] == "user") { print a[2] } }}' "${request_time_log}" | tail -n1)"
  request_phase_sys_s="$(awk '{for (i = 1; i <= NF; i++) { split($i, a, "="); if (a[1] == "sys") { print a[2] } }}' "${request_time_log}" | tail -n1)"
  request_phase_cpu_pct="$(awk '{for (i = 1; i <= NF; i++) { split($i, a, "="); if (a[1] == "cpu_pct") { gsub(/%$/, "", a[2]); print a[2] } }}' "${request_time_log}" | tail -n1)"
  request_phase_rss_kb="$(awk '{for (i = 1; i <= NF; i++) { split($i, a, "="); if (a[1] == "rss_kb") { print a[2] } }}' "${request_time_log}" | tail -n1)"
fi

echo "[4/4] done"
echo "endpoint:      ${ENDPOINT}"
echo "payload:       ${payload_desc}"
echo "requests:      ${REQUESTS}"
echo "concurrency:   ${CONCURRENCY}"
echo "success:       ${ok_count}"
echo "failed:        ${fail_count}"
echo "success_ratio: ${success_ratio}%"
echo "duration:      ${duration_sec}s"
echo "success_qps:   ${success_qps}"
echo "request_phase_elapsed_s: ${request_phase_elapsed_s}"
echo "request_phase_user_s:    ${request_phase_user_s}"
echo "request_phase_sys_s:     ${request_phase_sys_s}"
echo "request_phase_cpu_pct:   ${request_phase_cpu_pct}"
echo "request_phase_rss_kb:    ${request_phase_rss_kb}"
echo "logs:          ${LOG_DIR}"

if [[ "${fail_count}" -gt 0 ]]; then
  if [[ "${STRESS_MODE}" == "single-process" && "${RDMA}" == "true" && "${RDMA_DISABLE_FALLBACK}" == "true" && "${ok_count}" -eq 0 ]]; then
    echo "hint: relay may be stuck with stale RDMA sessions; restart rdma-http-relay on ${ENDPOINT} host or set RESTART_REMOTE_RELAY=true"
  fi
  if [[ "${STRESS_MODE}" == "single-process" ]]; then
    echo "failed_log: ${LOG_DIR}/batch.log"
  else
    first_failed="$(head -n1 "${fail_file}")"
    echo "first_failed_request: ${first_failed}"
    echo "first_failed_log: ${LOG_DIR}/req-${first_failed}.log"
  fi
  exit 2
fi
