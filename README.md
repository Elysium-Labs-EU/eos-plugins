# eos-plugins

[![Codeberg](https://img.shields.io/badge/Codeberg-eos--plugins-blue?logo=codeberg)](https://codeberg.org/Elysium_Labs/eos-plugins)

Log sink plugins for [eos](https://codeberg.org/Elysium_Labs/eos). Each plugin is a standalone binary that eos spawns as a subprocess, pipes JSON log records to via stdin, and restarts if it crashes.

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
curl -sSL https://codeberg.org/Elysium_Labs/eos-plugins/raw/branch/main/install.sh | sudo bash -s -- <plugin-name>
```

e.g. `-- eos-sink-loki`. The script detects your architecture, downloads the pre-built binary from the plugin's latest release, verifies the SHA256 checksum, and installs to `/usr/local/bin`.

To pin a specific version, set `EOS_PLUGIN_VERSION=v0.1.0` before running.

**From source:**

```bash
cd eos-sink-<name>
make install   # builds and installs to ~/.local/bin
```

**Local or private sink, no release needed:** point `service.yaml` straight at a binary path with `exec:`, bypassing the `eos-sink-<type>` PATH-naming convention entirely. See [PROTOCOL.md](PROTOCOL.md#local-and-private-sinks).

## Configuration

Sinks are declared in `service.yaml` under `log_sinks`:

```yaml
log_sinks:
  - type: loki
    mode: push
    address: "http://your-loki-host:3100"
```

`type` maps to a binary on PATH named `eos-sink-<type>` (or use `exec:` for a custom path). eos passes `address` via `EOS_SINK_ADDRESS` and `options` via `EOS_SINK_OPTIONS`. `mode` is `push` (plugin connects outward) or `serve` (plugin binds a local port); it is a documentation convention, not enforced by eos. See each plugin's own README for its specific options, and [PROTOCOL.md](PROTOCOL.md) for the full wire contract.

## License

Apache License 2.0; see [LICENSE](LICENSE).
