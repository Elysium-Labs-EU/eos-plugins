# Sink plugin protocol

This is the contract eos expects from a log sink plugin. Read this and you don't need to read eos core source to write one.

## Invocation

eos resolves the binary for a `service.yaml` entry with `type: <name>` by looking up `eos-sink-<name>` on `PATH`, then runs it with the entry's `args`, passing:

- `EOS_SINK_SERVICE` — the eos service name
- `EOS_SINK_TYPE` — the sink `type`
- `EOS_SINK_ADDRESS` — the sink entry's `address`
- `EOS_SINK_OPTIONS` — the sink entry's `options` map, JSON-encoded (string values are `$VAR`-expanded from the environment before encoding)

## Handshake

On startup, the plugin must write `READY\n` to stdout within **10 seconds**. eos buffers nothing before this; it will not send records until it sees `READY`, and kills the plugin if the timeout elapses. Anything the plugin writes to stdout after `READY` is currently discarded (reserved for a future ACK protocol) — don't rely on it being read.

## Record format

eos writes newline-delimited JSON to the plugin's stdin, one record per line:

```json
{"ts": "2026-07-06T10:00:00.000000000Z", "service": "my-app", "stream": "stdout", "msg": "server started on :8080"}
```

- `ts` — RFC3339Nano
- `service` — the eos service name (same value as `EOS_SINK_SERVICE`)
- `stream` — `stdout` or `stderr`
- `msg` — the log line

## Shutdown

eos closes stdin (EOF) to signal a graceful stop. The plugin should flush any buffered output and exit. eos waits up to **3 seconds** before killing the process.

## Crash and restart

If the plugin exits (crash or otherwise) while eos is still running, eos restarts it after a delay (`restart_delay_ms` in the sink config, default 5000ms). Buffered records are held in memory across restarts up to a bounded ring buffer; if the plugin is down long enough, oldest records are dropped.

Write plugin-side diagnostics to **stderr**, not stdout — eos captures stderr and surfaces it in its own logs. Stdout is reserved for `READY` and future ACK lines.

## `mode`

`mode: push` or `mode: serve` in the sink config is a documentation convention for plugin authors and users to describe the plugin's connection style — eos itself only checks that `mode` is non-empty, it never branches on the value. Set it to whichever accurately describes your plugin.

## Local and private sinks

If your sink will never be published as a release (internal/proprietary, or just local dev iteration), you don't need `install.sh` or the `eos-sink-<type>` PATH-naming convention at all. Set `exec:` on the sink entry in `service.yaml` to point directly at any binary path:

```yaml
log_sinks:
  - type: my-internal-sink
    exec: /opt/internal/bin/my-sink
    mode: push
    address: "http://internal-host:1234"
```

eos runs whatever `exec` points to, unchanged otherwise — same handshake, same record format, same env vars.

## Writing a new sink

1. Create `eos-sink-<name>/` with `main.go`. `eos-sink-loki` is the smallest reference implementation.
2. Add a `Makefile` with `build`, `install`, `build-linux`, and `release` targets — copy one from an existing plugin, they're identical apart from `BINARY_NAME`.
3. Add `eos-sink-<name>/README.md` covering your plugin's options.
4. Add an entry to the root [README.md](README.md#available-plugins) pointing at it (this is the only shared file you need to touch).
5. To publish a release: tag `eos-sink-<name>/vX.Y.Z` and push. The existing Forgejo workflow (`.forgejo/workflows/release.yml`) builds, tests, and publishes it automatically — no per-plugin CI config needed, it parses the plugin name out of the tag.
