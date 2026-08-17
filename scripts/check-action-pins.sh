#!/usr/bin/env bash
# Fails if a workflow references an action by anything other than a full
# commit SHA carrying a version comment.
#
# A tag is a mutable pointer. `@v7` resolves to whatever commit the action's
# owner last pointed it at, so a workflow nobody has touched can start running
# different code between two pushes. That matters most in release.yml, where
# the publishing step holds a token with write access to releases at the exact
# moment it uploads the binaries install.sh fetches and installs as root.
#
# The trailing `# vN` comment is load-bearing, not decoration: Dependabot's
# github-actions ecosystem reads it to know which version a SHA stands for.
# Without it the pin stops receiving bump PRs and silently rots at whatever
# commit it was frozen at.
set -euo pipefail

cd "$(dirname "$0")/.."

failures=0

fail() {
    echo "check-action-pins: $1" >&2
    failures=$((failures + 1))
}

shopt -s nullglob
workflows=(.github/workflows/*.yml .github/workflows/*.yaml)
if [ ${#workflows[@]} -eq 0 ]; then
    fail "no workflows found under .github/workflows"
    exit 1
fi

pinned=0
for workflow in "${workflows[@]}"; do
    while IFS= read -r line; do
        lineno="${line%%:*}"
        ref="$(printf '%s' "${line#*:}" | sed -E 's/.*uses:[[:space:]]*//')"

        # A local composite action is versioned by this repo's own history,
        # and a docker:// image carries its own digest convention.
        case "$ref" in
            ./*|docker://*) continue ;;
        esac

        if ! printf '%s' "$ref" | grep -Eq '^[^@]+@[0-9a-f]{40}([[:space:]]|$)'; then
            fail "${workflow}:${lineno} is not pinned to a commit SHA: ${ref}"
            continue
        fi

        if ! printf '%s' "$ref" | grep -Eq '#[[:space:]]*v?[0-9]'; then
            fail "${workflow}:${lineno} has no '# vN' version comment, so Dependabot cannot bump it: ${ref}"
            continue
        fi

        pinned=$((pinned + 1))
    done < <(grep -nE '^\s*-?\s*uses:' "$workflow")
done

if [ "$failures" -ne 0 ]; then
    echo "check-action-pins: ${failures} problem(s) found" >&2
    exit 1
fi

echo "check-action-pins: OK, ${pinned} action reference(s) pinned to a commit SHA"
