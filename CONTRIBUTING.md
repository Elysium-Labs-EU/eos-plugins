# Contributing to eos-plugins

## Prerequisites

Go 1.26 or later and `make` are required. Verify with `go version` and `make --version`.

## Setup

```bash
git clone https://github.com/Elysium-Labs-EU/eos-plugins
cd eos-plugins
```

There is no repo-wide build. Each `eos-sink-<name>/` directory is its own Go module with its own `go.mod` and `Makefile`; `cd` into the plugin you're changing before running anything. `make help` inside a plugin directory lists its targets (`build`, `install`, `build-linux`, `install-orb`, `release`).

## Making Changes

Adding a brand-new sink? Read [PROTOCOL.md](PROTOCOL.md) first — it defines the invocation, handshake, and record-format contract every sink must implement, and closes with a checklist for wiring one up. Existing sinks follow the same contract; keep changes to a plugin consistent with it.

Open an issue before starting work on a non-trivial change, such as adding a new sink or changing the wire protocol. This avoids duplicate effort and makes sure the direction fits the project. Small fixes and documentation improvements can go straight to a PR.

Branch from `main` and name the branch after the change: `feat/loki-tls-support`, `fix/otlp-reconnect-backoff`, `test/sse-broadcast-ordering`.

## Running Tests

CI lints and tests each plugin independently. From the plugin's own directory:

```bash
cd eos-sink-<name>
go test ./... -race
GOLANGCI_LINT_CACHE="$(git rev-parse --show-toplevel)/.cache/golangci-lint" golangci-lint run
```

Both must pass before opening a PR. A change to one plugin does not require touching the others; CI runs each plugin's checks separately and only fails for the plugins you changed.

Set `GOLANGCI_LINT_CACHE` per checkout as shown. golangci-lint's cache is keyed on file content, so identical sources in two worktrees collide in the one shared per-user cache and a clean tree can be served the other tree's stored findings, complete with the absolute paths recorded when they were first analysed. Keeping the cache inside the checkout makes collision impossible.

Changing `install.sh` also means running its own checks from the repo root:

```bash
shellcheck install.sh scripts/*.sh
./scripts/test-install.sh
```

`install.sh` is served to users straight from `main`, not from a release, so a change to it is live the moment it merges. Test it against a real release in a throwaway VM or container before opening the PR; it runs as root and writes to `/usr/local/bin`.

## Commit Format

eos-plugins uses [Conventional Commits](https://www.conventionalcommits.org). The prefix determines which section of the changelog the commit appears in.

```
feat: add TLS support to eos-sink-loki
fix: retry otlp connection on transient failure
test: cover sse broadcast under concurrent writers
refactor: extract shared stdin record parser
docs: document EOS_SINK_OPTIONS for eos-sink-logbench
chore: bump golangci-lint to v2.11.0
```

Breaking changes go in the commit footer: `BREAKING CHANGE: <description>`. Releases are tagged per plugin (`eos-sink-loki/v0.1.0`), so a breaking change to one sink does not force a version bump in the others.

## Opening a Pull Request

The PR description should explain *why* the change is needed, not just what it does. Link the issue it resolves with `Closes #N`.

All CI checks must be green. A PR that breaks lint or tests for any touched plugin will not be reviewed until it is fixed.
