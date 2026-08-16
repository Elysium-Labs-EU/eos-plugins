#!/usr/bin/env bash
# Unit-tests release.sh by sourcing the real script, the same way
# test-install.sh covers install.sh.
#
# The interesting behaviour is the verification half: a tag that pushed
# cleanly but started no workflow run must fail loudly. That path is driven
# here by overriding `gh` with a shell function, which shadows the real
# binary for the sourced script without any network access or repo state.
set -euo pipefail

cd "$(dirname "$0")/.."

PASSED=0
FAILED=0

# Stubs cannot record anything in a shell variable: run_exists_for pipes gh
# into grep, so the stub runs in a subshell and any counter it increments dies
# with it. Cases that need to observe how often a stub was called, or whether
# it was called at all, write to files here instead.
SCRATCH="$(mktemp -d)"
export SCRATCH
trap 'rm -rf "${SCRATCH}"' EXIT

# run sources release.sh and evaluates $script against it, comparing combined
# output to $want. Timeouts are cut to keep the polling tests instant.
run() {
    local desc="$1" script="$2" want="$3"
    local got
    got="$(EOS_PLUGIN_RUN_TIMEOUT=1 EOS_PLUGIN_RUN_POLL_INTERVAL=1 \
        bash -c "source scripts/release.sh; ${script}" 2>&1)" || true
    if [ "$got" = "$want" ]; then
        echo "PASS: $desc"
        PASSED=$((PASSED + 1))
    else
        echo "FAIL: $desc"
        echo "  want: $want"
        echo "  got:  $got"
        FAILED=$((FAILED + 1))
    fi
}

# --- validate_tag --------------------------------------------------------

run "accepts a well-formed release tag" \
    'validate_tag eos-sink-loki/v0.1.0 && printf ok' \
    "ok"

run "accepts a prerelease version" \
    'validate_tag eos-sink-otlp/v1.2.3-rc.4 && printf ok' \
    "ok"

run "rejects a tag with no plugin prefix" \
    'validate_tag v0.1.0 >/dev/null 2>&1 || printf rejected' \
    "rejected"

run "rejects a plugin name that is not a sink" \
    'validate_tag some-other-tool/v0.1.0 >/dev/null 2>&1 || printf rejected' \
    "rejected"

run "rejects a bare plugin name with no version" \
    'validate_tag eos-sink-loki >/dev/null 2>&1 || printf rejected' \
    "rejected"

# The workflow parses the version as ${TAG##*/}, so a third segment would be
# silently truncated to the last one rather than failing.
run "rejects a tag with more than two segments" \
    'validate_tag eos-sink-loki/nested/v0.1.0 >/dev/null 2>&1 || printf rejected' \
    "rejected"

run "rejects an empty plugin name" \
    'validate_tag eos-sink-/v0.1.0 >/dev/null 2>&1 || printf rejected' \
    "rejected"

# --- dispatch_hint -------------------------------------------------------

# The recovery path is only useful if it names the same plugin and version the
# workflow's own inputs expect.
run "dispatch hint splits the tag into the workflow's two inputs" \
    'dispatch_hint eos-sink-loki/v0.1.0' \
    "gh workflow run release.yml -f plugin=eos-sink-loki -f version=v0.1.0"

run "dispatch hint keeps prerelease suffixes intact" \
    'dispatch_hint eos-sink-sse/v0.2.0-rc.1' \
    "gh workflow run release.yml -f plugin=eos-sink-sse -f version=v0.2.0-rc.1"

# --- run_exists_for ------------------------------------------------------

# gh is stubbed to list runs for two other tags. A substring-tolerant match
# would wrongly find eos-sink-loki/v0.1.0 inside eos-sink-loki/v0.1.0-rc.1.
readonly GH_STUB='gh() { printf "%s\n" "eos-sink-loki/v0.1.0-rc.1" "eos-sink-sse/v0.3.0"; }'

run "finds an existing run for the pushed tag" \
    "${GH_STUB}; run_exists_for eos-sink-sse/v0.3.0 && printf found" \
    "found"

run "does not match a different tag that shares a prefix" \
    "${GH_STUB}; run_exists_for eos-sink-loki/v0.1.0 || printf missing" \
    "missing"

run "reports missing when gh lists no runs at all" \
    'gh() { :; }; run_exists_for eos-sink-loki/v0.1.0 || printf missing' \
    "missing"

# --- wait_for_run --------------------------------------------------------

run "returns as soon as the run exists" \
    "${GH_STUB}; wait_for_run eos-sink-sse/v0.3.0 && printf found" \
    "found"

run "gives up and fails when no run ever appears" \
    'gh() { :; }; wait_for_run eos-sink-loki/v0.1.0 || printf timeout' \
    "timeout"

# A run that only shows up after the first poll must still be found; failing
# here would make the timeout meaningless and every release flaky.
# shellcheck disable=SC2016  # run() hands this to `bash -c`; expansions belong there, not here.
run "keeps polling until a late run appears" \
    'printf 0 > "${SCRATCH}/polls"
     gh() {
         n=$(( $(cat "${SCRATCH}/polls") + 1 ))
         printf "%s" "$n" > "${SCRATCH}/polls"
         [ "$n" -ge 2 ] && printf "eos-sink-loki/v0.1.0\n"
     }
     EOS_PLUGIN_RUN_TIMEOUT=10 wait_for_run eos-sink-loki/v0.1.0 && printf found' \
    "found"

# --- release_tag ---------------------------------------------------------

# The failure that matters: the push succeeds, so nothing errors, but no run
# is ever created. This must be a nonzero exit naming the recovery command,
# not a silent success.
run "fails and prints the recovery command when a pushed tag starts no run" \
    'git() { :; }
     gh() { :; }
     release_tag eos-sink-loki/v0.1.0 >/dev/null 2>&1 || dispatch_hint eos-sink-loki/v0.1.0' \
    "gh workflow run release.yml -f plugin=eos-sink-loki -f version=v0.1.0"

run "succeeds when the pushed tag starts a run" \
    "git() { :; }; ${GH_STUB}
     release_tag eos-sink-sse/v0.3.0 >/dev/null 2>&1 && printf released" \
    "released"

# --- main ----------------------------------------------------------------

# Validation runs over every argument before the first push, so one bad tag
# at the end cannot leave earlier plugins half-released.
# shellcheck disable=SC2016  # run() hands this to `bash -c`; expansions belong there, not here.
# main exits rather than returns on a bad tag, so it runs in a subshell here;
# what it did is read back from the file its git stub would have written.
run "validates every tag before pushing any of them" \
    'git() { printf push >> "${SCRATCH}/pushed"; }
     gh() { :; }
     check_prerequisites() { :; }
     ( main eos-sink-loki/v0.1.0 not-a-tag ) >/dev/null 2>&1 || true
     printf "%s" "$(cat "${SCRATCH}/pushed" 2>/dev/null || printf none)"' \
    "none"

run "usage with no arguments exits nonzero" \
    '( main ) >/dev/null 2>&1 || printf usage' \
    "usage"

echo ""
echo "test-release: ${PASSED} passed, ${FAILED} failed"
[ "$FAILED" -eq 0 ]
