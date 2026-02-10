# rdma-http-demo

This directory contains a minimal end-to-end scaffold for the design we discussed:

- `server/`: HTTP relay server in front of local MinIO.
- `client/`: S3 SDK v2 client that talks to the relay server via `BaseEndpoint`.

Current state is a bootstrap version:

- Client is now wired to SDK RDMA transport (`s3.Options.RDMADialer`) and uses verbs dialer settings.
- Server now listens using RDMA verbs listener (not TCP listener).
- RDMA recv/send completion path uses hybrid CQ polling (short spin + sleep) and deadline-aware reads to avoid hanging `net/http` background reads.
- Relay now defaults to keepalive enabled (`-disable-client-keepalive=false`) to support long-running/high-concurrency clients.
- Build with `-tags rdma` and `CGO_ENABLED=1` to enable the verbs backend.

## 1) Deploy server node (10.0.1.2) with systemd MinIO + relay

From `10.0.1.1` run:

```bash
cd /users/Liquidz/sdk-rdma

REMOTE_HOST=10.0.1.2 \
REMOTE_USER=<your_ssh_user_on_10.0.1.2> \
MINIO_ROOT_USER=minioadmin \
MINIO_ROOT_PASSWORD=minioadmin \
GOTOOLCHAIN=go1.23.6 \
./rdma-http-demo/scripts/deploy_remote_server.sh
```

What this script does on `10.0.1.2`:

- installs `minio` binary to `/usr/local/bin/minio`
- creates and starts `minio.service` (systemd)
- installs relay binary to `/usr/local/bin/rdma-http-relay`
- creates and starts `rdma-http-relay.service` (systemd)

Remote defaults (current deployment):

- MinIO API: `:9000`
- MinIO Console: `:9001`
- relay RDMA listen: `:18080`
- relay upstream MinIO endpoint: `http://127.0.0.1:9000`

## 2) Verify remote services on 10.0.1.2

```bash
ssh <your_ssh_user_on_10.0.1.2>@10.0.1.2
sudo systemctl status minio --no-pager
sudo systemctl status rdma-http-relay --no-pager
curl http://127.0.0.1:9000/minio/health/live
```

Note: relay uses RDMA listener, so `curl http://127.0.0.1:18080/...` is not expected to work.

## 3) Run client on 10.0.1.1

```bash
cd ../client
export AWS_ACCESS_KEY_ID=minioadmin
export AWS_SECRET_ACCESS_KEY=minioadmin

CGO_ENABLED=1 GOTOOLCHAIN=go1.23.6 go run -tags rdma . \
  -endpoint http://10.0.1.2:18080 \
  -mode both \
  -bucket rdma-demo \
  -key hello.txt \
  -payload "hello via relay"
```

Useful flags:

- `-endpoint` (default `http://127.0.0.1:18080`)
- `-mode put|get|both`
- `-put-file <path>`
- `-get-out <path>`
- `-ensure-bucket=true|false`
- `-count`, `-concurrency` (single-process batch mode)
- `-rdma=true|false`
- `-rdma-disable-fallback=true|false`
- `-rdma-frame-payload`, `-rdma-sendq`, `-rdma-recvq`, `-rdma-inline`
- `-rdma-open-parallelism`, `-rdma-open-interval`
- `-request-timeout` (default `30s`, set `0` to disable)

## 4) Validate strict RDMA path (recommended)

Strict RDMA (no fallback, should succeed once server is RDMA listener):

```bash
CGO_ENABLED=1 GOTOOLCHAIN=go1.23.6 go run -tags rdma . \
  -endpoint http://10.0.1.2:18080 \
  -mode put -rdma=true -rdma-disable-fallback=true \
  -bucket rdma-demo -key rdma-strict.txt -payload "strict rdma"
```

Optional compatibility tuning (if your NIC/driver rejects default QP params):

```bash
CGO_ENABLED=1 GOTOOLCHAIN=go1.23.6 go run -tags rdma . \
  -endpoint http://10.0.1.2:18080 \
  -mode put -rdma=true -rdma-disable-fallback=true \
  -rdma-sendq=32 -rdma-recvq=32 -rdma-inline=1 \
  -bucket rdma-demo -key rdma-strict-tuned.txt -payload "strict rdma tuned"
```

## 5) Run concurrent stress from client node

```bash
cd /users/Liquidz/sdk-rdma

ENDPOINT=http://10.0.1.2:18080 \
REQUESTS=500 \
CONCURRENCY=32 \
REQUEST_TIMEOUT=20s \
ENSURE_BUCKET=false \
STRESS_MODE=single-process \
RDMA_OPEN_PARALLELISM=1 \
RDMA_OPEN_INTERVAL=200ms \
RESTART_REMOTE_RELAY=true \
REMOTE_USER=Liquidz \
RDMA=true \
RDMA_DISABLE_FALLBACK=true \
GOTOOLCHAIN=go1.23.6 \
./rdma-http-demo/scripts/stress_client.sh
```

The script will:

- build the client binary with `-tags rdma`
- run stress in `single-process` mode by default (`STRESS_MODE=single-process`) to reuse persistent RDMA connections
- in `single-process` mode, no separate warmup process is launched
- in `multi-process` mode, warmup runs first and `ENSURE_BUCKET` controls bucket bootstrap
- optional `STRESS_MODE=multi-process` is kept for reconnect-churn testing
- `RDMA_OPEN_PARALLELISM` / `RDMA_OPEN_INTERVAL` tune open pacing for bursty load
- optional `RESTART_REMOTE_RELAY=true` restarts `rdma-http-relay` via SSH before running (uses `REMOTE_HOST` or parses host from `ENDPOINT`)
- `INTER_REQUEST_SLEEP_MS` (multi-process mode only) can stagger process starts
- default payload in single-process mode is `stress-payload` (14 bytes)
- set `PUT_FILE=/path/to/payload.bin` to benchmark larger fixed payload sizes
- print success/failure ratio and success QPS
- save run logs under `/tmp/rdma-stress-logs-*`

## 6) Step4: high-concurrency relay tuning

`server` now supports overload protection and richer upstream pool tuning.

Typical high-load deployment knobs:

```bash
cd /users/Liquidz/sdk-rdma

REMOTE_HOST=10.0.1.2 \
REMOTE_USER=Liquidz \
RELAY_DISABLE_CLIENT_KEEPALIVE=false \
RELAY_ACCESS_LOG=false \
RELAY_STATS_INTERVAL=30s \
RELAY_MAX_INFLIGHT=4096 \
RELAY_UPSTREAM_MAX_IDLE_CONNS=2048 \
RELAY_UPSTREAM_MAX_IDLE_CONNS_PER_HOST=1024 \
RELAY_UPSTREAM_MAX_CONNS_PER_HOST=0 \
RELAY_UPSTREAM_IDLE_CONN_TIMEOUT=120s \
RELAY_UPSTREAM_RESPONSE_HEADER_TIMEOUT=15s \
RELAY_UPSTREAM_DISABLE_COMPRESSION=true \
RELAY_SERVER_READ_HEADER_TIMEOUT=10s \
RELAY_SERVER_IDLE_TIMEOUT=120s \
RELAY_SERVER_MAX_HEADER_BYTES=1048576 \
GOTOOLCHAIN=go1.23.6 \
./rdma-http-demo/scripts/deploy_remote_server.sh
```

Useful runtime signals in relay logs:

- `proxied ...` lines: per-request details (enabled when `RELAY_ACCESS_LOG=true`)
- `relay_stats ...` lines: low-overhead aggregate stats every `RELAY_STATS_INTERVAL`
- `overload ...` lines: requests dropped by `RELAY_MAX_INFLIGHT` overload shedding

## 7) Step5: benchmark matrix + client CPU sampling

Use the matrix script to sweep concurrency and collect CSV with:

- success/failure and QPS (from `stress_client.sh`)
- client CPU user/sys/% and RSS for the request phase only (from `/usr/bin/time` inside stress phase `[3/4]`)

```bash
cd /users/Liquidz/sdk-rdma

AWS_ACCESS_KEY_ID=minioadmin AWS_SECRET_ACCESS_KEY=minioadmin \
ENDPOINT=http://10.0.1.2:18080 \
REQUESTS=400 \
CONCURRENCY_LIST="1 2 4 8 16 32" \
ROUNDS=3 \
RDMA=true \
RDMA_DISABLE_FALLBACK=true \
RDMA_OPEN_PARALLELISM=1 \
RDMA_OPEN_INTERVAL=200ms \
RESTART_REMOTE_RELAY=true \
REMOTE_USER=Liquidz \
OUT_CSV=/tmp/rdma-step5-matrix.csv \
./rdma-http-demo/scripts/benchmark_client_matrix.sh
```

The generated CSV can be used directly for plotting or regression tracking.
Terminal summary now includes avg/median/P95/max for QPS and CPU.

Quick path-vs-path comparison (relay RDMA vs direct MinIO TCP):

```bash
cd /users/Liquidz/sdk-rdma

AWS_ACCESS_KEY_ID=minioadmin AWS_SECRET_ACCESS_KEY=minioadmin \
RELAY_ENDPOINT=http://10.0.1.2:18080 \
MINIO_ENDPOINT=http://10.0.1.2:9000 \
REQUESTS=400 \
CONCURRENCY_LIST="1 2 4 8 16 32" \
ROUNDS=3 \
REMOTE_USER=Liquidz \
OUT_DIR=/tmp/rdma-compare \
./rdma-http-demo/scripts/benchmark_compare_paths.sh
```

This writes:
- `relay_rdma.csv`
- `direct_minio_tcp.csv`
- `compare_merged.csv`
and prints avg/median/P95/max for QPS and CPU by `mode+concurrency`.

## 8) Payload sweep comparison (relay RDMA vs direct MinIO TCP)

Use this script to compare throughput/CPU across increasing payload sizes.
CPU metrics are still request-phase-only.

```bash
cd /users/Liquidz/sdk-rdma

AWS_ACCESS_KEY_ID=minioadmin AWS_SECRET_ACCESS_KEY=minioadmin \
RELAY_ENDPOINT=http://10.0.1.2:18080 \
MINIO_ENDPOINT=http://10.0.1.2:9000 \
PAYLOAD_SIZES="16 64 256 1024 4096 16384 65536 262144 1048576" \
REQUESTS=400 \
CONCURRENCY_LIST="1 2 4 8 16 32" \
ROUNDS=3 \
STRESS_MODE=single-process \
RELAY_RESTART_REMOTE_RELAY=false \
OUT_DIR=/tmp/rdma-payload-compare \
./rdma-http-demo/scripts/benchmark_compare_payloads.sh
```

This writes:
- `relay_rdma.csv`
- `direct_minio_tcp.csv`
- `compare_payload_merged.csv`
and prints avg/median/P95/max for QPS and CPU by `mode+payload+concurrency`.

## Notes

- Client uses local SDK modules via `replace` in `client/go.mod`.
- Client forces `UsePathStyle=true`, which is usually easier for gateway/proxy forwarding.
- Relay currently preserves request `Host` for SigV4 pass-through behavior.
