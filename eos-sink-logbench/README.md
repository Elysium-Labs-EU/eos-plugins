# eos-sink-logbench

Posts eos service log lines to [Logbench](https://logbench.dev)'s ingest API.

See the [wire protocol](../PROTOCOL.md) for how eos invokes plugins.

## Install

```bash
curl -sSL https://codeberg.org/Elysium_Labs/eos-plugins/raw/branch/main/install.sh | sudo bash -s -- eos-sink-logbench
```

Or from source: `cd eos-sink-logbench && make install`

## Configuration

```yaml
log_sinks:
  - type: logbench
    mode: push
    address: "http://your-logbench-host:1447"
    options:
      project_id: "your-project-id"
```

`address` (`EOS_SINK_ADDRESS`) is required, e.g. `http://logbench:1447`. `options.project_id` is required.

## License

Apache License 2.0; see [LICENSE](LICENSE).
