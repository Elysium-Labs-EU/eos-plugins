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

## License

Apache License 2.0; see [LICENSE](LICENSE).
