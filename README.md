# eos-plugins

[![GitHub](https://img.shields.io/badge/GitHub-eos--plugins-blue?logo=github)](https://github.com/Elysium-Labs-EU/eos-plugins)

Log sink plugins for [eos](https://github.com/Elysium-Labs-EU/eos). Each plugin is a standalone binary that eos spawns as a subprocess, pipes JSON log records to via stdin, and restarts if it crashes.

## Available plugins

Each plugin lives in its own `eos-sink-<name>/` directory with its own README covering configuration and options; browse the repo to see what's available:

- [`eos-sink-loki`](eos-sink-loki/README.md): forwards logs to Grafana Loki
- [`eos-sink-sse`](eos-sink-sse/README.md): broadcasts logs as Server-Sent Events over HTTP
- [`eos-sink-logbench`](eos-sink-logbench/README.md): ships logs to [Logbench](https://logbench.dev)
- [`eos-sink-otlp`](eos-sink-otlp/README.md): exports logs to an OpenTelemetry (OTLP) collector over gRPC

Want to add your own sink? See [PROTOCOL.md](PROTOCOL.md) for the wire contract and a checklist for adding a new plugin. No changes to this file are required; the directory itself is the listing.

## Install

**One-line install** (Linux, requires root):

```bash
curl -sSL https://raw.githubusercontent.com/Elysium-Labs-EU/eos-plugins/main/install.sh | sudo bash -s -- <plugin-name>
```

e.g. `-- eos-sink-loki`. The script detects your architecture, downloads the pre-built binary from the plugin's latest release, verifies the SHA256 checksum, and installs to `/usr/local/bin`.

To pin a specific version, set `EOS_PLUGIN_VERSION=v0.1.0` before running.

**From source:**

```bash
cd eos-sink-<name>
make install   # builds and installs to ~/.local/bin
```

**Local or private sink, no release needed:** point `service.yaml` straight at a binary path with `exec:`, bypassing the `eos-sink-<type>` PATH-naming convention entirely. See [PROTOCOL.md](PROTOCOL.md#local-and-private-sinks).

**Publishing your own installer** (a plugin outside this repo): see [PROTOCOL.md's installer contract](PROTOCOL.md#installer-contract) for what it needs to guarantee.

## Configuration

Sinks are declared in `service.yaml` under `log_sinks`, inline:

```yaml
log_sinks:
  - type: loki
    mode: push
    address: "http://your-loki-host:3100"
```

`type` maps to a binary on PATH named `eos-sink-<type>` (or use `exec:` for a custom path). See each plugin's own README for its specific `options`, and [PROTOCOL.md](PROTOCOL.md) for the full wire contract.

### Every field

| Field              | Required | Description |
|--------------------|----------|--------------|
| `type`             | yes      | Sink type. eos discovers the plugin binary as `eos-sink-<type>` on `PATH`. |
| `mode`              | yes      | `push` (plugin connects outward) or `serve` (plugin binds a local port). Documentation convention for describing the plugin's connection style; eos only checks it's non-empty, never branches on the value. |
| `address`           | yes      | Remote URL (`push`) or bind address (`serve`). Passed to the plugin via `EOS_SINK_ADDRESS`. |
| `exec`              | no       | Explicit path to the plugin binary, overriding the `eos-sink-<type>` PATH lookup. For local/private sinks that never publish a release: see [PROTOCOL.md](PROTOCOL.md#local-and-private-sinks). |
| `args`              | no       | Extra arguments passed to the plugin binary. |
| `streams`           | no       | Which output streams to route to this sink: `[stdout]`, `[stderr]`, or both (default). |
| `buffer_size`       | no       | Log records buffered in memory when the plugin is slow, oldest dropped on overflow. Default `4096`. |
| `restart_delay_ms`  | no       | Milliseconds to wait before restarting a crashed plugin. Default `5000`. |
| `options`           | no       | Plugin-specific config, passed as JSON via `EOS_SINK_OPTIONS`. String values are `$VAR`-expanded from the environment before encoding (e.g. `api_key: "${DD_API_KEY}"`). Not validated by eos. |

### Sharing one sink across services

When multiple services use the same sink, register it once in `~/.eos/config.yaml` and reference it by name instead of repeating the config in every `service.yaml`:

```yaml
# ~/.eos/config.yaml
sinks:
  prod-loki:
    type: loki
    mode: push
    address: "http://loki:3100"
```

```yaml
# service.yaml
log_sinks: [prod-loki, local-file]
```

Named references and inline configs compose in the same `log_sinks` list; the daemon resolves names at service start and errors on an unknown name. See [eos core's README](https://github.com/Elysium-Labs-EU/eos#log-sinks) for the authoritative version of this.

## License

Apache License 2.0; see [LICENSE](LICENSE).
