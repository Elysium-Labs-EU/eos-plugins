#!/usr/bin/env bash
# Unit-tests install.sh's pure functions by sourcing the real script rather
# than reimplementing its shell logic elsewhere. There's no root-level Go
# module in this repo (each eos-sink-* is its own module), so this is a
# bash harness instead of the Go-test-sources-install.sh pattern eos core
# uses -- same idea, different host language.
#
# fetch_latest_version is covered against a local HTTP stub via
# EOS_PLUGIN_API_BASE, which exists for exactly that purpose (mirroring
# EOS_API_BASE in eos core's installer). The stub keeps the test offline and
# deterministic; the same code path is also exercised against the real
# GitHub API during the VM install test.
set -euo pipefail

cd "$(dirname "$0")/.."

PASSED=0
FAILED=0

# run_with_fixture sources install.sh, pipes $fixture into the given
# function call, and compares its output against $want.
run_with_fixture() {
    local desc="$1" fixture="$2" call="$3" want="$4"
    local got
    got="$(FIXTURE="$fixture" bash -c "source install.sh; printf '%s' \"\$FIXTURE\" | ${call}" 2>&1)" || true
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

run() {
    local desc="$1" script="$2" want="$3"
    local got
    got="$(bash -c "source install.sh; ${script}" 2>&1)" || true
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

# --- select_plugin_version ---------------------------------------------

run_with_fixture "filters to the requested plugin among several published in one repo" \
    '[{"tag_name": "eos-sink-sse/v0.3.0", "prerelease": false}, {"tag_name": "eos-sink-loki/v0.1.0", "prerelease": false}]' \
    "select_plugin_version eos-sink-loki" \
    "v0.1.0"

run_with_fixture "picks highest stable by semver, not list position (out-of-order list)" \
    '[{"tag_name": "eos-sink-loki/v0.0.9-rc.1", "prerelease": true}, {"tag_name": "eos-sink-loki/v0.0.12-rc.5", "prerelease": true}, {"tag_name": "eos-sink-loki/v0.0.12-rc.4", "prerelease": true}]' \
    "select_plugin_version eos-sink-loki" \
    "v0.0.12-rc.5"

run_with_fixture "prefers a stable release over a newer prerelease" \
    '[{"tag_name": "eos-sink-loki/v0.2.0-rc.1", "prerelease": true}, {"tag_name": "eos-sink-loki/v0.1.0", "prerelease": false}]' \
    "select_plugin_version eos-sink-loki" \
    "v0.1.0"

run_with_fixture "falls back to the highest prerelease when no stable release exists" \
    '[{"tag_name": "eos-sink-loki/v0.1.0-rc.1", "prerelease": true}, {"tag_name": "eos-sink-loki/v0.1.0-rc.2", "prerelease": true}]' \
    "select_plugin_version eos-sink-loki" \
    "v0.1.0-rc.2"

run_with_fixture "empty for a plugin with no matching tags" \
    '[{"tag_name": "eos-sink-sse/v0.3.0", "prerelease": false}]' \
    "select_plugin_version eos-sink-loki" \
    ""

# --- fetch_latest_version (against a local stub of the releases API) -----

# Serves one fixed JSON body on any path, so fetch_latest_version's real
# curl call and URL building are exercised without reaching the network.
start_stub_server() {
    local body="$1" port_file="$2"
    python3 - "$body" "$port_file" <<'PY' &
import http.server, socketserver, sys, threading

body = sys.argv[1].encode()
port_file = sys.argv[2]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

with socketserver.TCPServer(("127.0.0.1", 0), Handler) as httpd:
    with open(port_file, "w") as f:
        f.write(str(httpd.server_address[1]))
    httpd.serve_forever()
PY
    STUB_PID=$!
}

if command -v python3 >/dev/null 2>&1; then
    stub_dir="$(mktemp -d)"
    port_file="${stub_dir}/port"
    # Deliberately a version that cannot exist upstream: if the override were
    # ignored and the call reached the real GitHub API, this test would fail
    # loudly instead of passing on a coincidental match with the live tag.
    start_stub_server '[{"tag_name": "eos-sink-loki/v9.9.9-rc.1", "prerelease": true}, {"tag_name": "eos-sink-loki/v9.9.8", "prerelease": false}]' "$port_file"

    for _ in $(seq 1 50); do
        [ -s "$port_file" ] && break
        sleep 0.1
    done

    if [ -s "$port_file" ]; then
        port="$(cat "$port_file")"
        run "fetch_latest_version resolves via EOS_PLUGIN_API_BASE, preferring stable" \
            "EOS_PLUGIN_API_BASE=http://127.0.0.1:${port} fetch_latest_version eos-sink-loki curl" \
            "v9.9.8"
    else
        echo "SKIP: stub server did not start; fetch_latest_version not covered"
    fi

    kill "${STUB_PID:-}" 2>/dev/null || true
    wait "${STUB_PID:-}" 2>/dev/null || true
    rm -rf "$stub_dir"
else
    echo "SKIP: python3 unavailable; fetch_latest_version not covered"
fi

# --- make_staging_dir ----------------------------------------------------

# The staging dir has to be gone once the installer exits, and present while
# it runs. Both halves are asserted from out here rather than from inside the
# script: the EXIT trap that removes it fires as the bash process dies, so an
# in-script check would pass whether or not the trap actually works.
staging_dir="$(bash -c 'source install.sh; make_staging_dir; printf "%s" "$tmp_dir"')"
if [ -n "$staging_dir" ]; then
    echo "PASS: make_staging_dir sets tmp_dir"
    PASSED=$((PASSED + 1))
else
    echo "FAIL: make_staging_dir set no tmp_dir"
    FAILED=$((FAILED + 1))
fi

if [ -n "$staging_dir" ] && [ ! -e "$staging_dir" ]; then
    echo "PASS: staging dir is removed when the installer exits"
    PASSED=$((PASSED + 1))
else
    echo "FAIL: staging dir ${staging_dir} still exists after the script exited"
    rm -rf "${staging_dir:?}"
    FAILED=$((FAILED + 1))
fi

# shellcheck disable=SC2016  # run() hands this to `bash -c`; $tmp_dir must expand there, not here.
run "staging dir is writable while the installer runs" \
    'make_staging_dir; touch "${tmp_dir}/probe" && [ -f "${tmp_dir}/probe" ] && printf ok' \
    "ok"

# --- detect_arch ---------------------------------------------------------

run "detect_arch maps x86_64 to amd64" \
    'uname() { echo x86_64; }; detect_arch' \
    "amd64"

run "detect_arch maps aarch64 to arm64" \
    'uname() { echo aarch64; }; detect_arch' \
    "arm64"

echo ""
echo "test-install: ${PASSED} passed, ${FAILED} failed"
[ "$FAILED" -eq 0 ]
