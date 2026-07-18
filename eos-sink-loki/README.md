# eos-sink-loki

> **Frozen (legacy).** This sink is maintained for existing users but receives no new features. It pushes to Loki's older `/loki/api/v1/push` API. For new deployments prefer [`eos-sink-otlp`](../eos-sink-otlp), which exports over OTLP and works with any OpenTelemetry backend, including Loki 3.0+ via its native OTLP endpoint. Grafana now recommends OTLP over backend specific exporters. See [issue #16](https://codeberg.org/Elysium_Labs/eos-plugins/issues/16).

Forwards eos service logs to Grafana Loki's `/loki/api/v1/push` endpoint.

Maps `stderr` stream to `level=error`, `stdout` to `level=info`. The `service` label is set from `EOS_SINK_SERVICE`, which eos populates automatically from the service name. See the [wire protocol](../PROTOCOL.md) for how eos invokes plugins.

## Install

```bash
curl -sSL https://codeberg.org/Elysium_Labs/eos-plugins/raw/branch/main/install.sh | sudo bash -s -- eos-sink-loki
```

Or from source: `cd eos-sink-loki && make install`

## Configuration

```yaml
log_sinks:
  - type: loki
    mode: push
    address: "http://your-loki-host:3100"
```

`address` (`EOS_SINK_ADDRESS`) is required. Example: `http://loki:3100`.

## License

Apache License 2.0; see [LICENSE](LICENSE).
