#!/usr/bin/env bash
# Fails if the golangci-lint version stops having exactly one source of truth.
#
# The version lives in .golangci-version and is read by both the plugin
# Makefiles and the CI workflows. Nothing about that arrangement is
# self-enforcing: a hardcoded version in a workflow, or a Makefile calling
# whatever golangci-lint is on PATH, reintroduces the split quietly and only
# shows up when two of them disagree about a specific line.
#
# That disagreement is not hypothetical. In a sibling repo three versions
# produced three verdicts on one unchanged line: one said a //nolint
# directive was required, one said the file was clean, one said the directive
# was dead and failed the run. Deleting it would have satisfied the local
# binary and broken the pre-commit hook, with CI never objecting.
set -euo pipefail

cd "$(dirname "$0")/.."

readonly VERSION_FILE=".golangci-version"
failures=0

fail() {
    echo "check-golangci-pin: $1" >&2
    failures=$((failures + 1))
}

if [ ! -f "$VERSION_FILE" ]; then
    fail "${VERSION_FILE} is missing; it is the single source of the linter version"
    exit 1
fi

version="$(tr -d '[:space:]' <"$VERSION_FILE")"

# A floating minor (v2.11) silently picks up new patch releases, so the same
# tree can start failing on a day nobody touched it. Dependabot does not bump
# this value -- it only rewrites `uses:` refs -- so the pin is deliberate and
# has to be exact to mean anything.
if ! printf '%s' "$version" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
    fail "${VERSION_FILE} holds '${version}', which is not an exact version (want e.g. v2.12.2)"
fi

for workflow in .github/workflows/*.yml; do
    # Only the resolve step may mention the file; any other literal version
    # next to the linter action is a second source of truth.
    if grep -n 'golangci' "$workflow" >/dev/null 2>&1; then
        if grep -nE '^\s*version:\s*v[0-9]' "$workflow" >/dev/null 2>&1; then
            fail "${workflow} hardcodes a golangci-lint version; read ${VERSION_FILE} instead"
            grep -nE '^\s*version:\s*v[0-9]' "$workflow" | sed 's/^/    /' >&2
        fi
    fi
done

for makefile in eos-sink-*/Makefile; do
    # shellcheck disable=SC2016  # a literal make expression, not a shell one
    if ! grep -q 'GOLANGCI_VERSION := \$(shell cat \$(CURDIR)/\.\./\.golangci-version)' "$makefile"; then
        fail "${makefile} does not read ${VERSION_FILE}"
    fi
    # A bare `golangci-lint` invocation resolves from PATH, which is the
    # divergence this whole arrangement exists to prevent.
    if grep -nE '^\s+golangci-lint (run|fmt)' "$makefile" >/dev/null 2>&1; then
        fail "${makefile} calls golangci-lint from PATH; use \$(GOLANGCI)"
    fi
done

if [ "$failures" -ne 0 ]; then
    echo "check-golangci-pin: ${failures} problem(s) found" >&2
    exit 1
fi

echo "check-golangci-pin: OK, golangci-lint pinned at ${version} in ${VERSION_FILE}"
