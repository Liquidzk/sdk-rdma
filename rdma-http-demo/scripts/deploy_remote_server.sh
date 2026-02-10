#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST="${REMOTE_HOST:-10.0.1.2}"
REMOTE_USER="${REMOTE_USER:-$USER}"
REMOTE="${REMOTE_USER}@${REMOTE_HOST}"

GO_TOOLCHAIN="${GOTOOLCHAIN:-go1.23.6}"

MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minioadmin}"
MINIO_DATA_DIR="${MINIO_DATA_DIR:-/var/lib/minio/data}"
MINIO_ADDRESS="${MINIO_ADDRESS:-:9000}"
MINIO_CONSOLE_ADDRESS="${MINIO_CONSOLE_ADDRESS:-:9001}"

RELAY_LISTEN_ADDR="${RELAY_LISTEN_ADDR:-:18080}"
RELAY_MINIO_ENDPOINT="${RELAY_MINIO_ENDPOINT:-http://127.0.0.1:9000}"
RELAY_DISABLE_CLIENT_KEEPALIVE="${RELAY_DISABLE_CLIENT_KEEPALIVE:-false}"
RELAY_ACCESS_LOG="${RELAY_ACCESS_LOG:-false}"
RELAY_STATS_INTERVAL="${RELAY_STATS_INTERVAL:-30s}"
RELAY_MAX_INFLIGHT="${RELAY_MAX_INFLIGHT:-0}"
RELAY_UPSTREAM_MAX_IDLE_CONNS="${RELAY_UPSTREAM_MAX_IDLE_CONNS:-1024}"
RELAY_UPSTREAM_MAX_IDLE_CONNS_PER_HOST="${RELAY_UPSTREAM_MAX_IDLE_CONNS_PER_HOST:-512}"
RELAY_UPSTREAM_MAX_CONNS_PER_HOST="${RELAY_UPSTREAM_MAX_CONNS_PER_HOST:-0}"
RELAY_UPSTREAM_IDLE_CONN_TIMEOUT="${RELAY_UPSTREAM_IDLE_CONN_TIMEOUT:-120s}"
RELAY_UPSTREAM_RESPONSE_HEADER_TIMEOUT="${RELAY_UPSTREAM_RESPONSE_HEADER_TIMEOUT:-15s}"
RELAY_UPSTREAM_DISABLE_COMPRESSION="${RELAY_UPSTREAM_DISABLE_COMPRESSION:-true}"
RELAY_SERVER_READ_HEADER_TIMEOUT="${RELAY_SERVER_READ_HEADER_TIMEOUT:-10s}"
RELAY_SERVER_READ_TIMEOUT="${RELAY_SERVER_READ_TIMEOUT:-0s}"
RELAY_SERVER_WRITE_TIMEOUT="${RELAY_SERVER_WRITE_TIMEOUT:-0s}"
RELAY_SERVER_IDLE_TIMEOUT="${RELAY_SERVER_IDLE_TIMEOUT:-120s}"
RELAY_SERVER_MAX_HEADER_BYTES="${RELAY_SERVER_MAX_HEADER_BYTES:-1048576}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SERVER_DIR="${REPO_ROOT}/rdma-http-demo/server"

if [[ ! -d "${SERVER_DIR}" ]]; then
  echo "server directory not found: ${SERVER_DIR}" >&2
  exit 1
fi

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need_cmd go
need_cmd ssh
need_cmd scp

TMP_BIN="$(mktemp /tmp/rdma-http-relay.XXXXXX)"
trap 'rm -f "${TMP_BIN}"' EXIT

echo "[1/5] building relay binary locally with ${GO_TOOLCHAIN}"
(
  cd "${SERVER_DIR}"
  GOTOOLCHAIN="${GO_TOOLCHAIN}" CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build -tags rdma -o "${TMP_BIN}" .
)

echo "[2/5] copying relay binary to ${REMOTE}"
scp "${TMP_BIN}" "${REMOTE}:/tmp/rdma-http-relay"

echo "[3/5] provisioning MinIO systemd service on ${REMOTE_HOST}"
echo "[4/5] provisioning relay systemd service on ${REMOTE_HOST}"
ssh "${REMOTE}" "sudo bash -s -- \
  $(printf '%q' "${MINIO_ROOT_USER}") \
  $(printf '%q' "${MINIO_ROOT_PASSWORD}") \
  $(printf '%q' "${MINIO_DATA_DIR}") \
  $(printf '%q' "${MINIO_ADDRESS}") \
  $(printf '%q' "${MINIO_CONSOLE_ADDRESS}") \
  $(printf '%q' "${RELAY_LISTEN_ADDR}") \
  $(printf '%q' "${RELAY_MINIO_ENDPOINT}") \
  $(printf '%q' "${RELAY_DISABLE_CLIENT_KEEPALIVE}") \
  $(printf '%q' "${RELAY_ACCESS_LOG}") \
  $(printf '%q' "${RELAY_STATS_INTERVAL}") \
  $(printf '%q' "${RELAY_MAX_INFLIGHT}") \
  $(printf '%q' "${RELAY_UPSTREAM_MAX_IDLE_CONNS}") \
  $(printf '%q' "${RELAY_UPSTREAM_MAX_IDLE_CONNS_PER_HOST}") \
  $(printf '%q' "${RELAY_UPSTREAM_MAX_CONNS_PER_HOST}") \
  $(printf '%q' "${RELAY_UPSTREAM_IDLE_CONN_TIMEOUT}") \
  $(printf '%q' "${RELAY_UPSTREAM_RESPONSE_HEADER_TIMEOUT}") \
  $(printf '%q' "${RELAY_UPSTREAM_DISABLE_COMPRESSION}") \
  $(printf '%q' "${RELAY_SERVER_READ_HEADER_TIMEOUT}") \
  $(printf '%q' "${RELAY_SERVER_READ_TIMEOUT}") \
  $(printf '%q' "${RELAY_SERVER_WRITE_TIMEOUT}") \
  $(printf '%q' "${RELAY_SERVER_IDLE_TIMEOUT}") \
  $(printf '%q' "${RELAY_SERVER_MAX_HEADER_BYTES}")" <<'REMOTE_SCRIPT'
set -euo pipefail

MINIO_ROOT_USER="$1"
MINIO_ROOT_PASSWORD="$2"
MINIO_DATA_DIR="$3"
MINIO_ADDRESS="$4"
MINIO_CONSOLE_ADDRESS="$5"
RELAY_LISTEN_ADDR="$6"
RELAY_MINIO_ENDPOINT="$7"
RELAY_DISABLE_CLIENT_KEEPALIVE="$8"
RELAY_ACCESS_LOG="$9"
RELAY_STATS_INTERVAL="${10}"
RELAY_MAX_INFLIGHT="${11}"
RELAY_UPSTREAM_MAX_IDLE_CONNS="${12}"
RELAY_UPSTREAM_MAX_IDLE_CONNS_PER_HOST="${13}"
RELAY_UPSTREAM_MAX_CONNS_PER_HOST="${14}"
RELAY_UPSTREAM_IDLE_CONN_TIMEOUT="${15}"
RELAY_UPSTREAM_RESPONSE_HEADER_TIMEOUT="${16}"
RELAY_UPSTREAM_DISABLE_COMPRESSION="${17}"
RELAY_SERVER_READ_HEADER_TIMEOUT="${18}"
RELAY_SERVER_READ_TIMEOUT="${19}"
RELAY_SERVER_WRITE_TIMEOUT="${20}"
RELAY_SERVER_IDLE_TIMEOUT="${21}"
RELAY_SERVER_MAX_HEADER_BYTES="${22}"

if ! command -v systemctl >/dev/null 2>&1; then
  echo "systemd is required on remote host" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required on remote host" >&2
  exit 1
fi

if ! ldconfig -p 2>/dev/null | grep -q 'librdmacm.so.1'; then
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    if ! apt-get install -y --no-install-recommends rdma-core libibverbs1 ibverbs-providers librdmacm1t64; then
      apt-get install -y --no-install-recommends rdma-core libibverbs1 ibverbs-providers librdmacm1
    fi
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y rdma-core libibverbs librdmacm
  elif command -v yum >/dev/null 2>&1; then
    yum install -y rdma-core libibverbs librdmacm
  else
    echo "missing librdmacm.so.1 and no supported package manager found" >&2
    exit 1
  fi
  ldconfig
fi

if ! id -u minio >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/minio --shell /usr/sbin/nologin minio
fi

if ! id -u rdmarelay >/dev/null 2>&1; then
  useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin rdmarelay
fi

install -d -m 0755 /etc/default
install -d -m 0755 /var/lib/minio
install -d -o minio -g minio -m 0750 "${MINIO_DATA_DIR}"

tmp_minio="$(mktemp /tmp/minio.bin.XXXXXX)"
if curl -fsSL https://dl.min.io/server/minio/release/linux-amd64/minio -o "${tmp_minio}"; then
  chmod 0755 "${tmp_minio}"
  install -m 0755 "${tmp_minio}" /usr/local/bin/minio.new
  mv -f /usr/local/bin/minio.new /usr/local/bin/minio
  rm -f "${tmp_minio}"
else
  rm -f "${tmp_minio}"
  if [[ ! -x /usr/local/bin/minio ]]; then
    echo "failed to download minio and no existing /usr/local/bin/minio present" >&2
    exit 1
  fi
  echo "warning: failed to download minio, keeping existing /usr/local/bin/minio"
fi

cat >/etc/default/minio <<EOF
MINIO_ROOT_USER=$(printf '%q' "${MINIO_ROOT_USER}")
MINIO_ROOT_PASSWORD=$(printf '%q' "${MINIO_ROOT_PASSWORD}")
MINIO_VOLUMES=$(printf '%q' "${MINIO_DATA_DIR}")
MINIO_ADDRESS=$(printf '%q' "${MINIO_ADDRESS}")
MINIO_CONSOLE_ADDRESS=$(printf '%q' "${MINIO_CONSOLE_ADDRESS}")
EOF
chmod 0600 /etc/default/minio

cat >/etc/systemd/system/minio.service <<'EOF'
[Unit]
Description=MinIO
Documentation=https://min.io/docs/
After=network-online.target
Wants=network-online.target

[Service]
User=minio
Group=minio
EnvironmentFile=/etc/default/minio
ExecStart=/usr/local/bin/minio server ${MINIO_VOLUMES} --address ${MINIO_ADDRESS} --console-address ${MINIO_CONSOLE_ADDRESS}
Restart=always
RestartSec=2
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

install -d -m 0755 /usr/local/bin
install -m 0755 /tmp/rdma-http-relay /usr/local/bin/rdma-http-relay
rm -f /tmp/rdma-http-relay

cat >/etc/default/rdma-http-relay <<EOF
LISTEN_ADDR=$(printf '%q' "${RELAY_LISTEN_ADDR}")
MINIO_ENDPOINT=$(printf '%q' "${RELAY_MINIO_ENDPOINT}")
DISABLE_CLIENT_KEEPALIVE=$(printf '%q' "${RELAY_DISABLE_CLIENT_KEEPALIVE}")
ACCESS_LOG=$(printf '%q' "${RELAY_ACCESS_LOG}")
STATS_INTERVAL=$(printf '%q' "${RELAY_STATS_INTERVAL}")
MAX_INFLIGHT=$(printf '%q' "${RELAY_MAX_INFLIGHT}")
UPSTREAM_MAX_IDLE_CONNS=$(printf '%q' "${RELAY_UPSTREAM_MAX_IDLE_CONNS}")
UPSTREAM_MAX_IDLE_CONNS_PER_HOST=$(printf '%q' "${RELAY_UPSTREAM_MAX_IDLE_CONNS_PER_HOST}")
UPSTREAM_MAX_CONNS_PER_HOST=$(printf '%q' "${RELAY_UPSTREAM_MAX_CONNS_PER_HOST}")
UPSTREAM_IDLE_CONN_TIMEOUT=$(printf '%q' "${RELAY_UPSTREAM_IDLE_CONN_TIMEOUT}")
UPSTREAM_RESPONSE_HEADER_TIMEOUT=$(printf '%q' "${RELAY_UPSTREAM_RESPONSE_HEADER_TIMEOUT}")
UPSTREAM_DISABLE_COMPRESSION=$(printf '%q' "${RELAY_UPSTREAM_DISABLE_COMPRESSION}")
SERVER_READ_HEADER_TIMEOUT=$(printf '%q' "${RELAY_SERVER_READ_HEADER_TIMEOUT}")
SERVER_READ_TIMEOUT=$(printf '%q' "${RELAY_SERVER_READ_TIMEOUT}")
SERVER_WRITE_TIMEOUT=$(printf '%q' "${RELAY_SERVER_WRITE_TIMEOUT}")
SERVER_IDLE_TIMEOUT=$(printf '%q' "${RELAY_SERVER_IDLE_TIMEOUT}")
SERVER_MAX_HEADER_BYTES=$(printf '%q' "${RELAY_SERVER_MAX_HEADER_BYTES}")
EOF
chmod 0644 /etc/default/rdma-http-relay

cat >/etc/systemd/system/rdma-http-relay.service <<'EOF'
[Unit]
Description=RDMA HTTP Relay Server
After=network-online.target minio.service
Wants=network-online.target
Requires=minio.service

[Service]
User=rdmarelay
Group=rdmarelay
EnvironmentFile=/etc/default/rdma-http-relay
ExecStart=/usr/local/bin/rdma-http-relay -listen=${LISTEN_ADDR} -minio-endpoint=${MINIO_ENDPOINT} -disable-client-keepalive=${DISABLE_CLIENT_KEEPALIVE} -access-log=${ACCESS_LOG} -stats-interval=${STATS_INTERVAL} -max-inflight=${MAX_INFLIGHT} -upstream-max-idle-conns=${UPSTREAM_MAX_IDLE_CONNS} -upstream-max-idle-conns-per-host=${UPSTREAM_MAX_IDLE_CONNS_PER_HOST} -upstream-max-conns-per-host=${UPSTREAM_MAX_CONNS_PER_HOST} -upstream-idle-conn-timeout=${UPSTREAM_IDLE_CONN_TIMEOUT} -upstream-response-header-timeout=${UPSTREAM_RESPONSE_HEADER_TIMEOUT} -upstream-disable-compression=${UPSTREAM_DISABLE_COMPRESSION} -server-read-header-timeout=${SERVER_READ_HEADER_TIMEOUT} -server-read-timeout=${SERVER_READ_TIMEOUT} -server-write-timeout=${SERVER_WRITE_TIMEOUT} -server-idle-timeout=${SERVER_IDLE_TIMEOUT} -server-max-header-bytes=${SERVER_MAX_HEADER_BYTES}
Restart=always
RestartSec=2
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

wait_http_ok() {
  local url="$1"
  local name="$2"
  local tries="${3:-60}"
  local i=1
  while (( i <= tries )); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      echo "$name is healthy: $url"
      return 0
    fi
    sleep 1
    ((i++))
  done
  echo "$name health check failed after ${tries}s: $url" >&2
  return 1
}

wait_service_active() {
  local svc="$1"
  local tries="${2:-60}"
  local i=1
  while (( i <= tries )); do
    if systemctl is-active --quiet "$svc"; then
      echo "$svc is active"
      return 0
    fi
    sleep 1
    ((i++))
  done
  echo "$svc did not become active after ${tries}s" >&2
  return 1
}

systemctl kill -s SIGKILL rdma-http-relay.service >/dev/null 2>&1 || true
systemctl reset-failed rdma-http-relay.service >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable --now minio.service
systemctl enable --now rdma-http-relay.service
systemctl restart minio.service rdma-http-relay.service

wait_http_ok "http://127.0.0.1${MINIO_ADDRESS}/minio/health/live" "minio"
wait_service_active "rdma-http-relay.service"

echo "remote services are healthy"
REMOTE_SCRIPT

echo "[5/5] done"
echo "MinIO: http://${REMOTE_HOST}${MINIO_ADDRESS}"
echo "Relay: http://${REMOTE_HOST}${RELAY_LISTEN_ADDR}"
echo "Client endpoint should be: -endpoint http://${REMOTE_HOST}${RELAY_LISTEN_ADDR}"
