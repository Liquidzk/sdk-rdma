# rdma-http-demo

This directory contains a minimal end-to-end scaffold for the design we discussed:

- `server/`: HTTP relay server in front of local MinIO.
- `client/`: S3 SDK v2 client that talks to the relay server via `BaseEndpoint`.

Current state is a bootstrap version:

- Client-to-server transport is standard HTTP with a replaceable `DialContext` hook.
- You can later replace the dialer with your RDMA-backed `net.Conn` implementation.

## 1) Start MinIO (no TLS)

Example via Docker:

```bash
docker run --rm -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER=minioadmin \
  -e MINIO_ROOT_PASSWORD=minioadmin \
  minio/minio server /data --console-address :9001
```

## 2) Run relay server

```bash
cd server
MINIO_ENDPOINT=http://127.0.0.1:9000 go run .
```

Defaults:

- listen address: `:18080`
- upstream MinIO endpoint: `http://127.0.0.1:9000`

Health check:

```bash
curl http://127.0.0.1:18080/_rdma_healthz
```

## 3) Run client

```bash
cd ../client
export AWS_ACCESS_KEY_ID=minioadmin
export AWS_SECRET_ACCESS_KEY=minioadmin

go run . -mode both -bucket rdma-demo -key hello.txt -payload "hello via relay"
```

Useful flags:

- `-endpoint` (default `http://127.0.0.1:18080`)
- `-mode put|get|both`
- `-put-file <path>`
- `-get-out <path>`
- `-ensure-bucket=true|false`

## Notes

- Client uses local SDK modules via `replace` in `client/go.mod`.
- Client forces `UsePathStyle=true`, which is usually easier for gateway/proxy forwarding.
- Relay currently preserves request `Host` for SigV4 pass-through behavior.
