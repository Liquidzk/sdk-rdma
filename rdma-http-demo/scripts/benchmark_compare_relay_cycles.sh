#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CLIENT_DIR="${REPO_ROOT}/rdma-http-demo/client"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need_cmd go
need_cmd perf
need_cmd awk

GOTOOLCHAIN="${GOTOOLCHAIN:-go1.23.6}"
CLIENT_BIN="${CLIENT_BIN:-/tmp/rdma-http-demo-client}"

PAYLOAD_FILE="${PAYLOAD_FILE:-/tmp/payload.bin}"
PAYLOAD_SIZE="${PAYLOAD_SIZE:-1024}"

RDMA_ENDPOINT="${RDMA_ENDPOINT:-http://10.0.1.2:18080}"
TCP_ENDPOINT="${TCP_ENDPOINT:-http://10.0.1.2:18081}"
BUCKET="${BUCKET:-rdma-demo}"
KEY_PREFIX="${KEY_PREFIX:-perf-relay}"

RPS_LIST="${RPS_LIST:-200 400 600 800}"
RUN_DURATION="${RUN_DURATION:-10s}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-40s}"
CONCURRENCY="${CONCURRENCY:-0}"
CLIENT_POOL_SIZE="${CLIENT_POOL_SIZE:-1}"
RETRY_MAX_ATTEMPTS="${RETRY_MAX_ATTEMPTS:-1}"

RDMA_FRAME_PAYLOAD="${RDMA_FRAME_PAYLOAD:-65536}"
RDMA_SENDQ="${RDMA_SENDQ:-128}"
RDMA_RECVQ="${RDMA_RECVQ:-128}"
RDMA_LOW_CPU="${RDMA_LOW_CPU:-true}"
RDMA_SEND_SIGNAL_INTERVAL="${RDMA_SEND_SIGNAL_INTERVAL:-8}"
RDMA_OPEN_PARALLELISM="${RDMA_OPEN_PARALLELISM:-0}"
RDMA_OPEN_INTERVAL="${RDMA_OPEN_INTERVAL:-0ms}"

OUT_DIR="${OUT_DIR:-/tmp/perf-relay-transport-cycles-$(date +%s)}"
mkdir -p "${OUT_DIR}/raw"

AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-${MINIO_ROOT_USER:-minioadmin}}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-${MINIO_ROOT_PASSWORD:-minioadmin}}"
AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"
if [[ -z "${AWS_ACCESS_KEY_ID}" || -z "${AWS_SECRET_ACCESS_KEY}" ]]; then
  echo "missing credentials: set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY (or MINIO_ROOT_USER/MINIO_ROOT_PASSWORD)" >&2
  exit 1
fi

echo "[1/4] build client: ${CLIENT_BIN}"
(
  cd "${CLIENT_DIR}"
  GOTOOLCHAIN="${GOTOOLCHAIN}" CGO_ENABLED=1 go build -tags rdma -o "${CLIENT_BIN}" .
)

echo "[2/4] prepare payload: ${PAYLOAD_FILE} (${PAYLOAD_SIZE} bytes)"
truncate -s "${PAYLOAD_SIZE}" "${PAYLOAD_FILE}"

SUMMARY_CSV="${OUT_DIR}/summary.csv"
echo "mode,endpoint,rps,exit_code,success,failed,task_clock,cycles_u,cycles_k,cycles_total,instructions_u,instructions_k,instructions_total,context_switches,cpu_migrations,page_faults,cycles_per_success,perf_file,run_log" > "${SUMMARY_CSV}"

get_ev() {
  local perf_file="$1"
  local ev="$2"
  awk -F, -v ev="${ev}" '$3==ev{gsub(/[[:space:]]/,"",$1); print $1; exit}' "${perf_file}"
}

norm() {
  local v="$1"
  if [[ -z "${v}" || "${v}" == "<notcounted>" || "${v}" == "<notsupported>" ]]; then
    echo 0
  else
    echo "${v}"
  fi
}

run_case() {
  local mode="$1"
  local endpoint="$2"
  local rdma_on="$3"
  local rps="$4"

  local perf_file="${OUT_DIR}/raw/${mode}-rps${rps}.perf.csv"
  local run_log="${OUT_DIR}/raw/${mode}-rps${rps}.run.log"

  local rdma_args=(
    -rdma="${rdma_on}"
    -rdma-disable-fallback=true
    -rdma-frame-payload="${RDMA_FRAME_PAYLOAD}"
    -rdma-sendq="${RDMA_SENDQ}"
    -rdma-recvq="${RDMA_RECVQ}"
    -rdma-low-cpu="${RDMA_LOW_CPU}"
    -rdma-send-signal-interval="${RDMA_SEND_SIGNAL_INTERVAL}"
    -rdma-open-parallelism="${RDMA_OPEN_PARALLELISM}"
    -rdma-open-interval="${RDMA_OPEN_INTERVAL}"
  )

  set +e
  sudo env \
    AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
    AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
    AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN}" \
    perf stat -x, --no-big-num \
      -e task-clock,cycles:u,cycles:k,instructions:u,instructions:k,context-switches,cpu-migrations,page-faults \
      -o "${perf_file}" \
      -- "${CLIENT_BIN}" \
      -endpoint "${endpoint}" \
      -mode put \
      -bucket "${BUCKET}" \
      -key "${KEY_PREFIX}-${mode}-${rps}.bin" \
      -put-file "${PAYLOAD_FILE}" \
      -ensure-bucket=false \
      -count=0 \
      -concurrency="${CONCURRENCY}" \
      -target-rps="${rps}" \
      -run-duration="${RUN_DURATION}" \
      -request-timeout="${REQUEST_TIMEOUT}" \
      -client-pool-size="${CLIENT_POOL_SIZE}" \
      -retry-max-attempts="${RETRY_MAX_ATTEMPTS}" \
      -conn-trace=false \
      -log-each-request=false \
      "${rdma_args[@]}" \
      > "${run_log}" 2>&1
  local rc=$?
  set -e

  local task_clock
  local cyc_u
  local cyc_k
  local ins_u
  local ins_k
  local csw
  local mig
  local pf
  local cyc_total
  local ins_total
  local success
  local failed
  local sf
  local cyc_per_succ

  task_clock="$(norm "$(get_ev "${perf_file}" task-clock)")"
  cyc_u="$(norm "$(get_ev "${perf_file}" cycles:u)")"
  cyc_k="$(norm "$(get_ev "${perf_file}" cycles:k)")"
  ins_u="$(norm "$(get_ev "${perf_file}" instructions:u)")"
  ins_k="$(norm "$(get_ev "${perf_file}" instructions:k)")"
  csw="$(norm "$(get_ev "${perf_file}" context-switches)")"
  mig="$(norm "$(get_ev "${perf_file}" cpu-migrations)")"
  pf="$(norm "$(get_ev "${perf_file}" page-faults)")"

  cyc_total="$(awk -v a="${cyc_u}" -v b="${cyc_k}" 'BEGIN{printf "%.0f", a+b}')"
  ins_total="$(awk -v a="${ins_u}" -v b="${ins_k}" 'BEGIN{printf "%.0f", a+b}')"

  sf="$(awk '/batch summary/ {for(i=1;i<=NF;i++){split($i,a,"="); if(a[1]=="success") s=a[2]; if(a[1]=="failed") f=a[2]}} END{printf "%d,%d", (s==""?0:s), (f==""?0:f)}' "${run_log}")"
  success="${sf%,*}"
  failed="${sf#*,}"

  if [[ "${success}" -gt 0 ]]; then
    cyc_per_succ="$(awk -v c="${cyc_total}" -v s="${success}" 'BEGIN{printf "%.0f", c/s}')"
  else
    cyc_per_succ=0
  fi

  echo "${mode},${endpoint},${rps},${rc},${success},${failed},${task_clock},${cyc_u},${cyc_k},${cyc_total},${ins_u},${ins_k},${ins_total},${csw},${mig},${pf},${cyc_per_succ},${perf_file},${run_log}" >> "${SUMMARY_CSV}"
  echo "[done] ${mode} endpoint=${endpoint} rps=${rps} rc=${rc} success=${success} failed=${failed} cycles_total=${cyc_total}"
}

echo "[3/4] run perf matrix"
for rps in ${RPS_LIST}; do
  run_case relay_rdma "${RDMA_ENDPOINT}" true "${rps}"
  run_case relay_tcp "${TCP_ENDPOINT}" false "${rps}"
done

echo
echo "[4/4] finished"
echo "summary: ${SUMMARY_CSV}"
if command -v column >/dev/null 2>&1; then
  column -s, -t "${SUMMARY_CSV}"
else
  cat "${SUMMARY_CSV}"
fi

echo
echo "rdma vs tcp (cycles_per_success, same relay path):"
awk -F, '
  NR == 1 { next }
  {
    key = $3
    if ($1 == "relay_rdma") rdma[key] = $17 + 0
    if ($1 == "relay_tcp")  tcp[key]  = $17 + 0
  }
  END {
    printf "%-10s %-18s %-18s %-12s\n", "rps", "rdma_cyc_per_succ", "tcp_cyc_per_succ", "rdma/tcp"
    for (k in rdma) {
      if (k in tcp) {
        ratio = (tcp[k] > 0 ? rdma[k] / tcp[k] : 0)
        printf "%-10s %-18.0f %-18.0f %-12.4f\n", k, rdma[k], tcp[k], ratio
      }
    }
  }
' "${SUMMARY_CSV}" | sort -k1,1n
