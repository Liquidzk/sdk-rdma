#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STRESS_SCRIPT="${REPO_ROOT}/rdma-http-demo/scripts/stress_client.sh"

if [[ ! -x "${STRESS_SCRIPT}" ]]; then
  echo "stress script not executable: ${STRESS_SCRIPT}" >&2
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

ENDPOINT="${ENDPOINT:-http://10.0.1.2:18080}"
REQUESTS="${REQUESTS:-0}"
CONCURRENCY_LIST="${CONCURRENCY_LIST:-0}"
ROUNDS="${ROUNDS:-3}"
ROUND_SLEEP_SEC="${ROUND_SLEEP_SEC:-0}"

REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-20s}"
REQUEST_TIMEOUT_HARD="${REQUEST_TIMEOUT_HARD:-120s}"
ENSURE_BUCKET="${ENSURE_BUCKET:-false}"
STRESS_MODE="${STRESS_MODE:-single-process}"
INTER_REQUEST_SLEEP_MS="${INTER_REQUEST_SLEEP_MS:-0}"
TARGET_RPS="${TARGET_RPS:-0}"
RUN_DURATION="${RUN_DURATION:-10s}"

RDMA="${RDMA:-true}"
RDMA_DISABLE_FALLBACK="${RDMA_DISABLE_FALLBACK:-true}"
RDMA_FRAME_PAYLOAD="${RDMA_FRAME_PAYLOAD:-0}"
RDMA_SENDQ="${RDMA_SENDQ:-0}"
RDMA_RECVQ="${RDMA_RECVQ:-0}"
RDMA_INLINE="${RDMA_INLINE:-0}"
RDMA_LOW_CPU="${RDMA_LOW_CPU:-true}"
RDMA_SEND_SIGNAL_INTERVAL="${RDMA_SEND_SIGNAL_INTERVAL:-0}"
RDMA_OPEN_PARALLELISM="${RDMA_OPEN_PARALLELISM:-0}"
RDMA_OPEN_INTERVAL="${RDMA_OPEN_INTERVAL:-0ms}"

RESTART_REMOTE_RELAY="${RESTART_REMOTE_RELAY:-true}"
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-$USER}"
REMOTE_RELAY_SERVICE="${REMOTE_RELAY_SERVICE:-rdma-http-relay}"

GO_TOOLCHAIN="${GOTOOLCHAIN:-go1.23.6}"
OUT_CSV="${OUT_CSV:-/tmp/rdma-bench-$(date +%s).csv}"

AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-${MINIO_ROOT_USER:-minioadmin}}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-${MINIO_ROOT_PASSWORD:-minioadmin}}"
AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"
if [[ -z "${AWS_ACCESS_KEY_ID}" || -z "${AWS_SECRET_ACCESS_KEY}" ]]; then
  echo "missing credentials: set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY (or MINIO_ROOT_USER/MINIO_ROOT_PASSWORD)" >&2
  exit 1
fi
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

if ! [[ "${ROUNDS}" =~ ^[0-9]+$ ]] || [[ "${ROUNDS}" -lt 1 ]]; then
  echo "invalid ROUNDS=${ROUNDS}, expected positive integer" >&2
  exit 1
fi

extract_metric() {
  local key="$1"
  local file="$2"
  awk -F':' -v k="$key" '
    $1 == k {
      v = $2
      gsub(/^[[:space:]]+/, "", v)
      print v
    }
  ' "${file}" | tail -n 1
}

mkdir -p "$(dirname "${OUT_CSV}")"
echo "timestamp,target_rps,run_duration,concurrency,round,exit_code,success,failed,success_ratio_pct,duration_s,success_qps,cpu_pct,user_s,sys_s,rss_kb,log_dir" >"${OUT_CSV}"

run_idx=0
for conc in ${CONCURRENCY_LIST}; do
  if ! [[ "${conc}" =~ ^[0-9]+$ ]] || [[ "${conc}" -lt 0 ]]; then
    echo "skip invalid concurrency value: ${conc}" >&2
    continue
  fi

  for ((round = 1; round <= ROUNDS; round++)); do
    run_idx=$((run_idx + 1))
    ts="$(date -Iseconds)"
    run_log="$(mktemp)"
    log_dir="/tmp/rdma-bench-run-${run_idx}-$(date +%s)"

    echo "[run ${run_idx}] conc=${conc} round=${round}/${ROUNDS}"
    set +e
    env \
      AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
      AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
      AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN}" \
      ENDPOINT="${ENDPOINT}" \
      REQUESTS="${REQUESTS}" \
      CONCURRENCY="${conc}" \
      REQUEST_TIMEOUT="${REQUEST_TIMEOUT}" \
      REQUEST_TIMEOUT_HARD="${REQUEST_TIMEOUT_HARD}" \
      ENSURE_BUCKET="${ENSURE_BUCKET}" \
      STRESS_MODE="${STRESS_MODE}" \
      INTER_REQUEST_SLEEP_MS="${INTER_REQUEST_SLEEP_MS}" \
      TARGET_RPS="${TARGET_RPS}" \
      RUN_DURATION="${RUN_DURATION}" \
      RDMA="${RDMA}" \
      RDMA_DISABLE_FALLBACK="${RDMA_DISABLE_FALLBACK}" \
      RDMA_FRAME_PAYLOAD="${RDMA_FRAME_PAYLOAD}" \
      RDMA_SENDQ="${RDMA_SENDQ}" \
      RDMA_RECVQ="${RDMA_RECVQ}" \
      RDMA_INLINE="${RDMA_INLINE}" \
      RDMA_LOW_CPU="${RDMA_LOW_CPU}" \
      RDMA_SEND_SIGNAL_INTERVAL="${RDMA_SEND_SIGNAL_INTERVAL}" \
      RDMA_OPEN_PARALLELISM="${RDMA_OPEN_PARALLELISM}" \
      RDMA_OPEN_INTERVAL="${RDMA_OPEN_INTERVAL}" \
      RESTART_REMOTE_RELAY="${RESTART_REMOTE_RELAY}" \
      REMOTE_HOST="${REMOTE_HOST}" \
      REMOTE_USER="${REMOTE_USER}" \
      REMOTE_RELAY_SERVICE="${REMOTE_RELAY_SERVICE}" \
      LOG_DIR="${log_dir}" \
      GOTOOLCHAIN="${GO_TOOLCHAIN}" \
      "${STRESS_SCRIPT}" 2>&1 | tee "${run_log}"
    rc=${PIPESTATUS[0]}
    set -e

    success="$(extract_metric "success" "${run_log}")"
    failed="$(extract_metric "failed" "${run_log}")"
    success_ratio="$(extract_metric "success_ratio" "${run_log}" | sed 's/%$//')"
    duration_s="$(extract_metric "duration" "${run_log}" | sed 's/s$//')"
    success_qps="$(extract_metric "success_qps" "${run_log}")"
    target_rps="$(extract_metric "target_rps" "${run_log}")"
    run_duration="$(extract_metric "run_duration" "${run_log}")"
    run_logs="$(extract_metric "logs" "${run_log}")"

    cpu_pct="$(extract_metric "request_phase_cpu_pct" "${run_log}")"
    user_s="$(extract_metric "request_phase_user_s" "${run_log}")"
    sys_s="$(extract_metric "request_phase_sys_s" "${run_log}")"
    rss_kb="$(extract_metric "request_phase_rss_kb" "${run_log}")"

    success="${success:-0}"
    failed="${failed:-0}"
    success_ratio="${success_ratio:-0}"
    duration_s="${duration_s:-0}"
    success_qps="${success_qps:-0}"
    target_rps="${target_rps:-${TARGET_RPS}}"
    run_duration="${run_duration:-${RUN_DURATION}}"
    cpu_pct="${cpu_pct:-0}"
    user_s="${user_s:-0}"
    sys_s="${sys_s:-0}"
    rss_kb="${rss_kb:-0}"
    run_logs="${run_logs:-${log_dir}}"

    if [[ "${rc}" -ne 0 && "${success}" == "0" && "${failed}" == "0" ]]; then
      if [[ "${REQUESTS}" -gt 0 ]]; then
        failed="${REQUESTS}"
      else
        failed="1"
      fi
    fi

    echo "${ts},${target_rps},${run_duration},${conc},${round},${rc},${success},${failed},${success_ratio},${duration_s},${success_qps},${cpu_pct},${user_s},${sys_s},${rss_kb},${run_logs}" >>"${OUT_CSV}"

    rm -f "${run_log}"
    if [[ "${ROUND_SLEEP_SEC}" != "0" ]]; then
      sleep "${ROUND_SLEEP_SEC}"
    fi
  done
done

echo
echo "benchmark csv: ${OUT_CSV}"
echo "cpu scope: request phase only"
echo "summary by concurrency+target_rps+run_duration:"
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
    key = $4 "|" $2 "|" $3
    n[key]++
    succ[key] += $7
    fail[key] += $8
    qps[key, n[key]] = $11 + 0
    cpu[key, n[key]] = $12 + 0
  }
  END {
    printf "%-12s %-12s %-12s %-8s %-10s %-10s %-10s %-10s %-10s %-10s %-10s %-10s %-10s %-10s\n", "concurrency", "target_rps", "run_dur", "runs", "avg_succ", "avg_fail", "avg_qps", "med_qps", "p95_qps", "max_qps", "avg_cpu%", "med_cpu%", "p95_cpu%", "max_cpu%"
    for (key in n) {
      split(key, a, "|")
      conc = a[1]
      target = a[2]
      run_dur = a[3]
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

      printf "%-12s %-12s %-12s %-8d %-10.2f %-10.2f %-10.2f %-10.2f %-10.2f %-10.2f %-10.2f %-10.2f %-10.2f %-10.2f\n",
        conc, target, run_dur, m, succ[key]/m, fail[key]/m, sum_q/m, med_q, p95_q, max_q, sum_cpu/m, med_cpu, p95_cpu, max_cpu

      for (i = 1; i <= m; i++) {
        delete q[i]
        delete cp[i]
      }
    }
  }
' "${OUT_CSV}" | sort -k1,1n -k2,2n -k3,3
