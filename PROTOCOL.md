# Sink plugin protocol

This is the contract eos expects from a log sink plugin. Read this and you don't need to read eos core source to write one.

## Invocation

eos resolves the binary for a `service.yaml` entry with `type: <name>` by looking up `eos-sink-<name>` on `PATH`, then runs it with the entry's `args`, passing:

- `EOS_SINK_SERVICE` — the eos service name
- `EOS_SINK_TYPE` — the sink `type`
- `EOS_SINK_ADDRESS` — the sink entry's `address`
- `EOS_SINK_OPTIONS` — the sink entry's `options` map, JSON-encoded (string values are `$VAR`-expanded from the environment before encoding)
- `EOS_SINK_PROTOCOL_VERSION` — the highest wire-protocol version this eos speaks (see [Handshake](#handshake))

## Handshake

On startup, the plugin must write `READY\n` to stdout within **10 seconds**. eos buffers nothing before this; it will not send records until it sees `READY`, and kills the plugin if the timeout elapses. Anything the plugin writes to stdout after the handshake line is currently discarded (reserved for a future ACK protocol) — don't rely on it being read.

### Protocol version

The `READY` line may carry the protocol version the plugin speaks:

```
READY 1
```

A bare `READY` means version 1, the format described in this document. **That will never become an error**, so a plugin written before this section existed keeps working and does not need to be updated. Anything after the version token is reserved and ignored.

eos accepts any version at or below its own and speaks the lower of the two. A version *above* what eos speaks is refused: eos kills the plugin and logs both numbers, since it can always serve an older plugin and never a newer one. A version token that isn't a positive integer is refused the same way.

Read `EOS_SINK_PROTOCOL_VERSION` if you want to decide before the handshake, either to adapt to an older eos or to exit with a message of your own rather than being killed. Plugins are released independently of eos and `exec:` sinks are never released at all, so no version pairing is guaranteed.

Only version 1 exists today. There is nothing to negotiate yet; the mechanism is here so the first format change doesn't strand plugins in the field.

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

## Installer contract

Any script that installs an eos plugin — this repo's shared `install.sh`, or a third party's own, for a plugin published outside this repo — should guarantee the following. Nothing enforces this automatically; it's on the installer's author, the same way wire-protocol compliance above is on the plugin's author.

- **Integrity**: verify a checksum (SHA256 or stronger) before installing. Detached-signature verification (like eos core's `sha256sums.txt.sig`) is a stronger guarantee and recommended, but not required today — this repo's own `install.sh` is checksum-only for now.
- **Atomicity**: download and verify into a private temp location (`mktemp -d`, cleaned up on every exit path), then move the verified binary into place. A partial or corrupt binary must never be observable at the final install path. A predictable temp path (e.g. `/tmp/<name>` instead of `mktemp`) is a symlink-attack surface when the installer runs as root.
- **Idempotency**: re-running the installer for the same version is safe and produces the same result.
- **Fails closed**: an unsupported architecture, failed download, or checksum mismatch exits nonzero and leaves no partial state on the target system.
- **Guides the user**: warn (don't necessarily block) if the parent tool isn't present on `PATH`; confirm after install that the binary actually resolves on `PATH` (the `eos-sink-<type>` lookup depends on it); print the `service.yaml` snippet needed next.
- **Env var convention**: `<PREFIX>_INSTALL_DIR` and `<PREFIX>_VERSION` for the install location and a version pin, mirroring `EOS_PLUGIN_INSTALL_DIR`/`EOS_PLUGIN_VERSION` here.

A plugin added to this repo (see below) inherits this contract for free through the shared `install.sh` and doesn't need its own installer.

## Writing a new sink

1. Create `eos-sink-<name>/` with `main.go`. `eos-sink-loki` is the smallest reference implementation.
2. Add a `Makefile` with `build`, `install`, `build-linux`, and `release` targets — copy one from an existing plugin, they're identical apart from `BINARY_NAME`.
3. Add `eos-sink-<name>/README.md` covering your plugin's options.
4. Add an entry to the root [README.md](README.md#available-plugins) pointing at it. This is the only shared file you need to touch; the shared `install.sh` already satisfies the [installer contract](#installer-contract) above for any plugin published in this repo.
5. To publish a release: tag `eos-sink-<name>/vX.Y.Z` and push. The release workflow (`.github/workflows/release.yml`) builds, tests, and publishes it automatically — no per-plugin CI config needed, it parses the plugin name out of the tag.

Releasing more than one plugin at a time goes through `scripts/release.sh`:

```bash
./scripts/release.sh eos-sink-loki/v0.1.0 eos-sink-sse/v0.2.0
```

GitHub Actions does not create tag events when more than three tags are pushed at once, and this repo ships four plugins — so tagging the whole set in one `git push` produces no workflow run, no error, and four tags on the remote that look released and aren't. The script pushes one tag per push and then waits for each tag's run to appear, so a tag that triggers nothing fails loudly with the `workflow_dispatch` command that publishes it instead.
