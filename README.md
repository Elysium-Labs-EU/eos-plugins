# eos-plugins

[![Codeberg](https://img.shields.io/badge/Codeberg-eos--plugins-blue?logo=codeberg)](https://codeberg.org/Elysium_Labs/eos-plugins)

Log sink plugins for [eos](https://codeberg.org/Elysium_Labs/eos). Each plugin is a standalone binary that eos spawns as a subprocess, pipes JSON log records to via stdin, and restarts if it crashes.

Three plugins are available: `eos-sink-loki` forwards logs to Grafana Loki, `eos-sink-sse` broadcasts them as Server-Sent Events over HTTP, and `eos-sink-logbench` ships them to [Logbench](https://logbench.dev).

## Install

**One-line install** (Linux, requires root):

```bash
curl -sSL https://codeberg.org/Elysium_Labs/eos-plugins/raw/branch/main/install.sh | sudo bash -s -- eos-sink-loki
```

Replace `eos-sink-loki` with whichever plugin you need. The script detects your architecture, downloads the pre-built binary from the latest release, verifies the SHA256 checksum, and installs to `/usr/local/bin`.

To pin a specific version, set `EOS_PLUGIN_VERSION=v0.1.0` before running.

**From source:**

```bash
cd eos-sink-loki
make install   # builds and installs to ~/.local/bin
```

## Configuration

Sinks are declared in `service.yaml` under `log_sinks`. eos passes `address` to the plugin via `EOS_SINK_ADDRESS` and `options` via `EOS_SINK_OPTIONS`.

`mode` is either `push` (plugin connects outward to a remote) or `serve` (plugin binds a local port).

```yaml
log_sinks:
  - type: loki
    mode: push
    address: "http://your-loki-host:3100"

  - type: sse
    mode: serve
    address: ":9000"

  - type: logbench
    mode: push
    address: "http://your-logbench-host:1447"
    options:
      project_id: "your-project-id"
```

### eos-sink-loki

Pushes each log line to Loki's `/loki/api/v1/push` endpoint. Maps `stderr` stream to `level=error`, `stdout` to `level=info`. The `service` label is set from `EOS_SINK_SERVICE`, which eos populates automatically from the service name.

`EOS_SINK_ADDRESS` is required. Example: `http://loki:3100`.

### eos-sink-sse

Starts an HTTP server and broadcasts each log line as a Server-Sent Event on `/stream`. Useful for live log tailing in a browser or custom dashboard.

`EOS_SINK_ADDRESS` is required. Example: `:9000`. Connect with:

```bash
curl -N http://your-host:9000/stream
```

### eos-sink-logbench

Posts each log line to Logbench's ingest API. Requires a project ID in `options`.

`EOS_SINK_ADDRESS` is required. Example: `http://logbench:1447`. `project_id` must be set in `options`.

## Log record format

eos emits newline-delimited JSON to the plugin's stdin:

```json
{"ts": "2026-07-06T10:00:00.000000000Z", "stream": "stdout", "msg": "server started on :8080"}
```

`stream` is `stdout` or `stderr`. `ts` is RFC3339Nano.

## License

Apache License 2.0; see [LICENSE](LICENSE).
