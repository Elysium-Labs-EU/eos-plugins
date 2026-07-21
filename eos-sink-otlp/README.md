# eos-sink-otlp

Exports eos service logs to an OpenTelemetry (OTLP) collector over gRPC.

Maps `stderr` stream to severity Error, `stdout` to severity Info, and records the source stream as a `log.iostream` attribute on each log record. The service name defaults to `EOS_SINK_SERVICE`, which eos populates automatically from the service name; override it with the `service_name` option. See the [wire protocol](../PROTOCOL.md) for how eos invokes plugins.

## Install

```bash
curl -sSL https://raw.githubusercontent.com/Elysium-Labs-EU/eos-plugins/main/install.sh | sudo bash -s -- eos-sink-otlp
```

Or from source: `cd eos-sink-otlp && make install`

## Configuration

```yaml
log_sinks:
  - type: otlp
    mode: push
    address: "https://otel-collector:4317"
    options:
      service_name: my-app
      headers:
        authorization: "Bearer $OTLP_TOKEN"
      insecure: false
```

`address` (`EOS_SINK_ADDRESS`) is required. Its scheme selects transport security: `https://` uses TLS, while `http://` or a bare `host:port` connects insecurely. The scheme is stripped before the host is passed to the gRPC exporter, so `https://otel-collector:4317` and `otel-collector:4317` both target the same endpoint but differ in whether TLS is used.

The target must accept OTLP over gRPC; some backends (for example Grafana Loki) ingest OTLP only over HTTP, so route the plugin through an OpenTelemetry Collector (plugin sends OTLP gRPC to the collector, which forwards to the backend) rather than pointing it straight at them.

### Options

Options are passed as a JSON map via `EOS_SINK_OPTIONS`; string values are `$VAR`-expanded from the environment before eos encodes them.

- `service_name`: overrides the OTLP `service.name` resource attribute. Defaults to `EOS_SINK_SERVICE`.
- `headers`: a map of gRPC metadata headers sent with every export, for example an `authorization` header for a collector that requires auth.
- `insecure`: when `true`, forces an insecure connection even for an `https://` address. An `http://` or bare address is always insecure regardless of this flag.

## Collector on a different host

`address` above works well when the collector is local or already reachable over a network you trust. If the collector is on another VPS, or on a machine behind NAT (e.g. your home network) that can't accept inbound connections, don't reach for TLS/token config here — tunnel loopback-to-loopback over SSH instead, so this plugin always dials `127.0.0.1:<port>` and never needs to know the collector isn't local.

`tunnel-setup` (in [`tunnel-setup/`](tunnel-setup/)) automates that: it generates a single-purpose SSH key, prints the exact restricted `authorized_keys` line to add on the other host, registers the tunnel itself as an **eos-managed service** (`eos run -f`) rather than a systemd unit or launchd plist, and self-tests the round trip. Registering it under `eos` — the same supervisor already running the real service — is what makes this identical on Linux, macOS, or anywhere else `eos` runs, with no root or dedicated system account needed.

```bash
cd tunnel-setup && go build -o tunnel-setup .

# On the eos/service host, tunneling out to a collector on another VPS:
./tunnel-setup -remote-host collector.example.com

# On the collector host (e.g. your home machine, behind NAT), dialing out
# to the VPS running eos so eos's loopback reaches back here:
./tunnel-setup -direction reverse -remote-host vps.example.com
```

Run `./tunnel-setup -h` for all options. It only ever touches the host it runs on — the far side's user/key/collector setup is a separate, explicit step it prints instructions for, never done for you silently.

**Keep eos itself alive.** The tunnel (and this host's telemetry, since it rides the same tunnel) is only as durable as the `eos` daemon supervising it — run `eos system startup` on this host so the OS restarts `eos` if it ever crashes (the tool prompts for this, but can't do it unattended since `eos system startup` itself asks an interactive y/n with no flag to skip it).

**`eos`'s own restart cap is separate and worth knowing about.** `eos`'s health monitor gives up restarting a specific service after `health.maxRestart` consecutive failures (default 10, in `~/.eos/config.yaml`) — a genuinely prolonged outage on the far side could exhaust that before it resolves, leaving the tunnel in a `failed (stale)` state until someone runs `eos run <service>` manually. Raise `maxRestart` on hosts where that's a real risk; there's no "unlimited" sentinel, just a bigger number.

**Set an absence alert on the collector side** (e.g. "no data from `service.name=<your service>` in N minutes") regardless of the above — a dead pipe can't be counted on to report its own death, so detect the gap from outside it.

A note if you ever hand-roll this yourself instead of using the tool: an `authorized_keys` entry like `restrict,permitopen="127.0.0.1:4317"` looks correct against `sshd(8)`'s own documented example, but `restrict` disables port-forwarding as a gate separate from `permitopen`'s allow-list, and `permitopen` alone does not reopen it — at least as of OpenSSH 10.2. You need `restrict,port-forwarding,permitopen="127.0.0.1:4317"` (the tool gets this right). Without `port-forwarding`, the tunnel process stays up and the local listening port opens fine, but every connection through it gets silently refused — test the actual round trip, not just that the local socket opens.

## License

Apache License 2.0; see [LICENSE](LICENSE).
