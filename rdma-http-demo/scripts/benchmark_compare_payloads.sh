#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BENCH_SCRIPT="${REPO_ROOT}/rdma-http-demo/scripts/benchmark_client_matrix.sh"

if [[ ! -x "${BENCH_SCRIPT}" ]]; then
  echo "benchmark script not executable: ${BENCH_SCRIPT}" >&2
  exit 1
fi

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need_cmd awk
need_cmd sed
need_cmd mktemp
need_cmd truncate

REQUESTS="${REQUESTS:-400}"
CONCURRENCY_LIST="${CONCURRENCY_LIST:-1 2 4 8 16 32}"
ROUNDS="${ROUNDS:-3}"
ROUND_SLEEP_SEC="${ROUND_SLEEP_SEC:-0}"

REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-20s}"
REQUEST_TIMEOUT_HARD="${REQUEST_TIMEOUT_HARD:-120s}"
ENSURE_BUCKET="${ENSURE_BUCKET:-false}"
STRESS_MODE="${STRESS_MODE:-single-process}"
INTER_REQUEST_SLEEP_MS="${INTER_REQUEST_SLEEP_MS:-0}"

RDMA_OPEN_PARALLELISM="${RDMA_OPEN_PARALLELISM:-1}"
RDMA_OPEN_INTERVAL="${RDMA_OPEN_INTERVAL:-200ms}"

RELAY_ENDPOINT="${RELAY_ENDPOINT:-http://10.0.1.2:18080}"
RELAY_RESTART_REMOTE_RELAY="${RELAY_RESTART_REMOTE_RELAY:-false}"
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-$USER}"
REMOTE_RELAY_SERVICE="${REMOTE_RELAY_SERVICE:-rdma-http-relay}"

MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://10.0.1.2:9000}"

PAYLOAD_SIZES="${PAYLOAD_SIZES:-16 64 256 1024 4096 16384 65536 262144 1048576}"
KEEP_PAYLOAD_FILES="${KEEP_PAYLOAD_FILES:-false}"

GO_TOOLCHAIN="${GOTOOLCHAIN:-go1.23.6}"
OUT_DIR="${OUT_DIR:-/tmp/rdma-payload-compare-$(date +%s)}"
PAYLOAD_DIR="${PAYLOAD_DIR:-${OUT_DIR}/payloads}"
mkdir -p "${OUT_DIR}" "${PAYLOAD_DIR}"

RELAY_CSV="${OUT_DIR}/relay_rdma.csv"
DIRECT_CSV="${OUT_DIR}/direct_minio_tcp.csv"
MERGED_CSV="${OUT_DIR}/compare_payload_merged.csv"

AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-${MINIO_ROOT_USER:-minioadmin}}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-${MINIO_ROOT_PASSWORD:-minioadmin}}"
AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"
if [[ -z "${AWS_ACCESS_KEY_ID}" || -z "${AWS_SECRET_ACCESS_KEY}" ]]; then
  echo "missing credentials: set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY (or MINIO_ROOT_USER/MINIO_ROOT_PASSWORD)" >&2
  exit 1
fi
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

echo "payload_bytes,timestamp,concurrency,round,exit_code,success,failed,success_ratio_pct,duration_s,success_qps,cpu_pct,user_s,sys_s,rss_kb,log_dir" >"${RELAY_CSV}"
echo "payload_bytes,timestamp,concurrency,round,exit_code,success,failed,success_ratio_pct,duration_s,success_qps,cpu_pct,user_s,sys_s,rss_kb,log_dir" >"${DIRECT_CSV}"
echo "mode,payload_bytes,timestamp,concurrency,round,exit_code,success,failed,success_ratio_pct,duration_s,success_qps,cpu_pct,user_s,sys_s,rss_kb,log_dir" >"${MERGED_CSV}"

run_matrix_once() {
  local mode="$1"
  local payload_bytes="$2"
  local endpoint="$3"
  local rdma="$4"
  local rdma_disable_fallback="$5"
  local restart_remote_relay="$6"
  local put_file="$7"
  local append_csv="$8"

  local tmp_csv
  tmp_csv="$(mktemp)"
  env \
    AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
    AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
    AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN}" \
    ENDPOINT="${endpoint}" \
    REQUESTS="${REQUESTS}" \
    CONCURRENCY_LIST="${CONCURRENCY_LIST}" \
    ROUNDS="${ROUNDS}" \
    ROUND_SLEEP_SEC="${ROUND_SLEEP_SEC}" \
    REQUEST_TIMEOUT="${REQUEST_TIMEOUT}" \
    REQUEST_TIMEOUT_HARD="${REQUEST_TIMEOUT_HARD}" \
    ENSURE_BUCKET="${ENSURE_BUCKET}" \
    STRESS_MODE="${STRESS_MODE}" \
    INTER_REQUEST_SLEEP_MS="${INTER_REQUEST_SLEEP_MS}" \
    RDMA="${rdma}" \
    RDMA_DISABLE_FALLBACK="${rdma_disable_fallback}" \
    RDMA_OPEN_PARALLELISM="${RDMA_OPEN_PARALLELISM}" \
    RDMA_OPEN_INTERVAL="${RDMA_OPEN_INTERVAL}" \
    RESTART_REMOTE_RELAY="${restart_remote_relay}" \
    REMOTE_HOST="${REMOTE_HOST}" \
    REMOTE_USER="${REMOTE_USER}" \
    REMOTE_RELAY_SERVICE="${REMOTE_RELAY_SERVICE}" \
    PUT_FILE="${put_file}" \
    OUT_CSV="${tmp_csv}" \
    GOTOOLCHAIN="${GO_TOOLCHAIN}" \
    "${BENCH_SCRIPT}"

  tail -n +2 "${tmp_csv}" | sed "s/^/${payload_bytes},/" >>"${append_csv}"
  tail -n +2 "${tmp_csv}" | sed "s/^/${mode},${payload_bytes},/" >>"${MERGED_CSV}"
  rm -f "${tmp_csv}"
}

for payload_bytes in ${PAYLOAD_SIZES}; do
  if ! [[ "${payload_bytes}" =~ ^[0-9]+$ ]] || [[ "${payload_bytes}" -lt 1 ]]; then
    echo "skip invalid payload size: ${payload_bytes}" >&2
    continue
  fi

  payload_file="${PAYLOAD_DIR}/payload-${payload_bytes}.bin"
  truncate -s "${payload_bytes}" "${payload_file}"

  echo
  echo "[payload ${payload_bytes}B][1/2] relay RDMA path: ${RELAY_ENDPOINT}"
  run_matrix_once "relay_rdma" "${payload_bytes}" "${RELAY_ENDPOINT}" "true" "true" "${RELAY_RESTART_REMOTE_RELAY}" "${payload_file}" "${RELAY_CSV}"

  echo
  echo "[payload ${payload_bytes}B][2/2] direct MinIO TCP path: ${MINIO_ENDPOINT}"
  run_matrix_once "direct_minio_tcp" "${payload_bytes}" "${MINIO_ENDPOINT}" "false" "false" "false" "${payload_file}" "${DIRECT_CSV}"
done

if [[ "${KEEP_PAYLOAD_FILES}" != "true" ]]; then
  rm -f "${PAYLOAD_DIR}"/payload-*.bin 2>/dev/null || true
fi

echo
echo "merged csv: ${MERGED_CSV}"
echo "relay csv:  ${RELAY_CSV}"
echo "direct csv: ${DIRECT_CSV}"
echo "cpu scope: request phase only"
echo
echo "summary by mode+payload+concurrency:"
awk -F',' '
  function sort_numeric(arr, n,    i, j, tmp) {
    for (i = 1; i <= n; i++) {
      for (j = i + 1; j <= n; j++) {
        if (arr[i] > arr[j]) {
          tmp = arr[i]
          arr[i] = arr[j]
          arr[j] = tmp
        }
      }
    }
  }
  NR == 1 { next }
  {
    key = $1 "|" $2 "|" $4
    n[key]++
    succ[key] += $7
    fail[key] += $8
    qps[key, n[key]] = $11 + 0
    cpu[key, n[key]] = $12 + 0
  }
  END {
    printf "%-18s %-14s %-12s %-8s %-10s %-10s %-10s %-10s %-10s %-10s %-10s %-10s %-10s %-10s\n", "mode", "payload_bytes", "concurrency", "runs", "avg_succ", "avg_fail", "avg_qps", "med_qps", "p95_qps", "max_qps", "avg_cpu%", "med_cpu%", "p95_cpu%", "max_cpu%"
    for (key in n) {
      split(key, a, "|")
      m = n[key]
      sum_q = 0
      sum_cpu = 0
      for (i = 1; i <= m; i++) {
        q[i] = qps[key, i]
        cp[i] = cpu[key, i]
        sum_q += q[i]
        sum_cpu += cp[i]
      }

      sort_numeric(q, m)
      sort_numeric(cp, m)

      if (m % 2 == 1) {
        med_q = q[(m + 1) / 2]
        med_cpu = cp[(m + 1) / 2]
      } else {
        med_q = (q[m / 2] + q[m / 2 + 1]) / 2
        med_cpu = (cp[m / 2] + cp[m / 2 + 1]) / 2
      }

      p95_idx = int((m * 95 + 99) / 100)
      if (p95_idx < 1) p95_idx = 1
      if (p95_idx > m) p95_idx = m
      p95_q = q[p95_idx]
      max_q = q[m]
      p95_cpu = cp[p95_idx]
      max_cpu = cp[m]

      printf "%-18s %-14s %-12s %-8d %-10.2f %-10.2f %-10.2f %-10.2f %-10.2f %-10.2f %-10.2f %-10.2f %-10.2f %-10.2f\n",
        a[1], a[2], a[3], m, succ[key]/m, fail[key]/m, sum_q/m, med_q, p95_q, max_q, sum_cpu/m, med_cpu, p95_cpu, max_cpu

      for (i = 1; i <= m; i++) {
        delete q[i]
        delete cp[i]
      }
    }
  }
' "${MERGED_CSV}" | sort -k2,2n -k3,3n -k1,1
