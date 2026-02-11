#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BENCH_SCRIPT="${REPO_ROOT}/rdma-http-demo/scripts/benchmark_client_matrix.sh"

if [[ ! -x "${BENCH_SCRIPT}" ]]; then
  echo "benchmark script not executable: ${BENCH_SCRIPT}" >&2
  exit 1
fi

REQUESTS="${REQUESTS:-0}"
CONCURRENCY_LIST="${CONCURRENCY_LIST:-0}"
ROUNDS="${ROUNDS:-3}"
ROUND_SLEEP_SEC="${ROUND_SLEEP_SEC:-0}"
TARGET_RPS="${TARGET_RPS:-0}"
RUN_DURATION="${RUN_DURATION:-10s}"

REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-20s}"
REQUEST_TIMEOUT_HARD="${REQUEST_TIMEOUT_HARD:-120s}"
ENSURE_BUCKET="${ENSURE_BUCKET:-false}"

RDMA_OPEN_PARALLELISM="${RDMA_OPEN_PARALLELISM:-0}"
RDMA_OPEN_INTERVAL="${RDMA_OPEN_INTERVAL:-200ms}"
RDMA_LOW_CPU="${RDMA_LOW_CPU:-true}"
RDMA_SEND_SIGNAL_INTERVAL="${RDMA_SEND_SIGNAL_INTERVAL:-0}"

RELAY_ENDPOINT="${RELAY_ENDPOINT:-http://10.0.1.2:18080}"
RELAY_RESTART_REMOTE_RELAY="${RELAY_RESTART_REMOTE_RELAY:-true}"
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-$USER}"
REMOTE_RELAY_SERVICE="${REMOTE_RELAY_SERVICE:-rdma-http-relay}"

MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://10.0.1.2:9000}"

GO_TOOLCHAIN="${GOTOOLCHAIN:-go1.23.6}"
OUT_DIR="${OUT_DIR:-/tmp/rdma-compare-$(date +%s)}"
mkdir -p "${OUT_DIR}"

RELAY_CSV="${OUT_DIR}/relay_rdma.csv"
DIRECT_CSV="${OUT_DIR}/direct_minio_tcp.csv"
MERGED_CSV="${OUT_DIR}/compare_merged.csv"

AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-${MINIO_ROOT_USER:-minioadmin}}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-${MINIO_ROOT_PASSWORD:-minioadmin}}"
AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"
if [[ -z "${AWS_ACCESS_KEY_ID}" || -z "${AWS_SECRET_ACCESS_KEY}" ]]; then
  echo "missing credentials: set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY (or MINIO_ROOT_USER/MINIO_ROOT_PASSWORD)" >&2
  exit 1
fi
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

echo "[1/3] benchmark relay path (RDMA): ${RELAY_ENDPOINT}"
env \
  ENDPOINT="${RELAY_ENDPOINT}" \
  REQUESTS="${REQUESTS}" \
  CONCURRENCY_LIST="${CONCURRENCY_LIST}" \
  ROUNDS="${ROUNDS}" \
  ROUND_SLEEP_SEC="${ROUND_SLEEP_SEC}" \
  REQUEST_TIMEOUT="${REQUEST_TIMEOUT}" \
  REQUEST_TIMEOUT_HARD="${REQUEST_TIMEOUT_HARD}" \
  ENSURE_BUCKET="${ENSURE_BUCKET}" \
  TARGET_RPS="${TARGET_RPS}" \
  RUN_DURATION="${RUN_DURATION}" \
  RDMA=true \
  RDMA_DISABLE_FALLBACK=true \
  RDMA_LOW_CPU="${RDMA_LOW_CPU}" \
  RDMA_SEND_SIGNAL_INTERVAL="${RDMA_SEND_SIGNAL_INTERVAL}" \
  RDMA_OPEN_PARALLELISM="${RDMA_OPEN_PARALLELISM}" \
  RDMA_OPEN_INTERVAL="${RDMA_OPEN_INTERVAL}" \
  RESTART_REMOTE_RELAY="${RELAY_RESTART_REMOTE_RELAY}" \
  REMOTE_HOST="${REMOTE_HOST}" \
  REMOTE_USER="${REMOTE_USER}" \
  REMOTE_RELAY_SERVICE="${REMOTE_RELAY_SERVICE}" \
  OUT_CSV="${RELAY_CSV}" \
  GOTOOLCHAIN="${GO_TOOLCHAIN}" \
  "${BENCH_SCRIPT}"

echo
echo "[2/3] benchmark direct MinIO path (TCP): ${MINIO_ENDPOINT}"
env \
  ENDPOINT="${MINIO_ENDPOINT}" \
  REQUESTS="${REQUESTS}" \
  CONCURRENCY_LIST="${CONCURRENCY_LIST}" \
  ROUNDS="${ROUNDS}" \
  ROUND_SLEEP_SEC="${ROUND_SLEEP_SEC}" \
  REQUEST_TIMEOUT="${REQUEST_TIMEOUT}" \
  REQUEST_TIMEOUT_HARD="${REQUEST_TIMEOUT_HARD}" \
  ENSURE_BUCKET="${ENSURE_BUCKET}" \
  TARGET_RPS="${TARGET_RPS}" \
  RUN_DURATION="${RUN_DURATION}" \
  RDMA=false \
  RDMA_DISABLE_FALLBACK=false \
  RESTART_REMOTE_RELAY=false \
  OUT_CSV="${DIRECT_CSV}" \
  GOTOOLCHAIN="${GO_TOOLCHAIN}" \
  "${BENCH_SCRIPT}"

echo
echo "[3/3] merge and compare"
{
  echo "mode,timestamp,target_rps,run_duration,concurrency,round,exit_code,success,failed,success_ratio_pct,duration_s,success_qps,cpu_pct,user_s,sys_s,rss_kb,log_dir"
  tail -n +2 "${RELAY_CSV}" | sed 's/^/relay_rdma,/'
  tail -n +2 "${DIRECT_CSV}" | sed 's/^/direct_minio_tcp,/'
} >"${MERGED_CSV}"

echo "merged csv: ${MERGED_CSV}"
echo "relay csv:  ${RELAY_CSV}"
echo "direct csv: ${DIRECT_CSV}"
echo
echo "summary by mode+concurrency+target_rps+run_duration (cpu scope: request phase only):"
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
    key = $1 "|" $5 "|" $3 "|" $4
    n[key]++
    succ[key] += $8
    fail[key] += $9
    qps[key, n[key]] = $12 + 0
    cpu[key, n[key]] = $13 + 0
  }
  END {
    printf "%-18s %-12s %-12s %-12s %-8s %-10s %-10s %-10s %-10s %-10s %-10s %-10s %-10s %-10s %-10s\n", "mode", "concurrency", "target_rps", "run_dur", "runs", "avg_succ", "avg_fail", "avg_qps", "med_qps", "p95_qps", "max_qps", "avg_cpu%", "med_cpu%", "p95_cpu%", "max_cpu%"
    for (key in n) {
      split(key, a, "|")
      mode = a[1]
      conc = a[2]
      target = a[3]
      run_dur = a[4]
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

      printf "%-18s %-12s %-12s %-12s %-8d %-10.2f %-10.2f %-10.2f %-10.2f %-10.2f %-10.2f %-10.2f %-10.2f %-10.2f %-10.2f\n",
        mode, conc, target, run_dur, m, succ[key]/m, fail[key]/m, sum_q/m, med_q, p95_q, max_q, sum_cpu/m, med_cpu, p95_cpu, max_cpu

      for (i = 1; i <= m; i++) {
        delete q[i]
        delete cp[i]
      }
    }
  }
' "${MERGED_CSV}" | sort -k2,2n -k3,3n -k4,4 -k1,1
