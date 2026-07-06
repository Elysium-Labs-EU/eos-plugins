# eos-plugins

[![Codeberg](https://img.shields.io/badge/Codeberg-eos--plugins-blue?logo=codeberg)](https://codeberg.org/Elysium_Labs/eos-plugins)

Log sink plugins for [eos](https://codeberg.org/Elysium_Labs/eos).

Each plugin is a standalone binary. eos pipes JSON log records to the plugin's stdin; the plugin prints `READY` once it's accepting input, then forwards every line to its destination.

## Plugins

| Plugin | Forwards to | Default address |
|--------|-------------|-----------------|
| `eos-sink-loki` | Grafana Loki | `http://localhost:3100` |
| `eos-sink-sse` | Server-Sent Events (HTTP) | `:9000` |
| `eos-sink-logbench` | [Logbench](https://logbench.dev) | `http://localhost:1447` |

## Install

Each plugin builds independently. From the plugin directory:

```bash
# Build and install to ~/.local/bin
make install

# Cross-compile for Linux amd64
make build-linux
```

Or from source:

```bash
cd eos-sink-loki
CGO_ENABLED=0 go build -o eos-sink-loki .
```

## Configuration

### eos-sink-loki

Pushes each log line to Loki's `/loki/api/v1/push` endpoint. Maps `stderr` → `level=error`, `stdout` → `level=info`.

| Variable | Default | Description |
|----------|---------|-------------|
| `EOS_SINK_ADDRESS` | `http://localhost:3100` | Loki base URL |
| `EOS_SINK_SERVICE` | _(empty)_ | Value for the `service` label on every log entry |

### eos-sink-sse

Starts an HTTP server and broadcasts each log line as a Server-Sent Event. Connect to `/stream` to receive the feed. Useful for live log tailing in a browser or dashboard.

| Variable | Default | Description |
|----------|---------|-------------|
| `EOS_SINK_ADDRESS` | `:9000` | Bind address for the SSE server |

### eos-sink-logbench

Posts each log line to Logbench's ingest API. Requires a project ID.

| Variable | Required | Description |
|----------|----------|-------------|
| `EOS_SINK_OPTIONS` | yes | JSON: `{"project_id": "your-id", "endpoint": "http://localhost:1447"}` |

`endpoint` defaults to `http://localhost:1447` if omitted from the JSON.

## Log record format

eos emits newline-delimited JSON:

```json
{"ts": "2026-07-06T10:00:00.000000000Z", "stream": "stdout", "msg": "server started on :8080"}
```

`stream` is `stdout` or `stderr`. `ts` is RFC3339Nano.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
