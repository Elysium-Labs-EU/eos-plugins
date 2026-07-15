# eos-sink-sse

Starts an HTTP server and broadcasts each eos service log line as a Server-Sent Event on `/stream`. Useful for live log tailing in a browser or custom dashboard.

See the [wire protocol](../PROTOCOL.md) for how eos invokes plugins.

## Install

```bash
curl -sSL https://codeberg.org/Elysium_Labs/eos-plugins/raw/branch/main/install.sh | sudo bash -s -- eos-sink-sse
```

Or from source: `cd eos-sink-sse && make install`

## Configuration

```yaml
log_sinks:
  - type: sse
    mode: serve
    address: ":9000"
```

`address` (`EOS_SINK_ADDRESS`) is required, e.g. `:9000`. Connect with:

```bash
curl -N http://your-host:9000/stream
```

## License

Apache License 2.0; see [LICENSE](LICENSE).
