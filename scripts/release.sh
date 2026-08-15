#!/usr/bin/env bash
# Tags and publishes plugin releases, one tag per push.
#
# GitHub Actions does not create tag events when more than three tags arrive
# in a single push:
#
#   "Events will not be created for tags when more than three tags are pushed
#    at once."
#
# This repo ships four plugins, so releasing the whole set in one `git push`
# is both the obvious command and exactly the case that silently produces no
# workflow run at all -- the tags land on the remote and every check short of
# opening the Actions tab reports success.
#
# Pushing one tag per push sidesteps that rule, but a push succeeding still
# does not prove a run started: Actions disabled on the repo, a tag pattern
# that stopped matching, or a workflow that no longer parses all fail exactly
# as quietly. So each push is followed by a poll for the run it should have
# produced, and a tag with no run is a hard error naming the workflow_dispatch
# command that recovers it.
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

readonly WORKFLOW="release.yml"

# Seconds to wait for a tag's workflow run to appear. GitHub queues the run
# before it starts, so this is dispatch latency, not build time.
RUN_TIMEOUT="${EOS_PLUGIN_RUN_TIMEOUT:-90}"
RUN_POLL_INTERVAL="${EOS_PLUGIN_RUN_POLL_INTERVAL:-5}"

info()    { echo -e "${CYAN}${BOLD}info${NC} $1"; }
success() { echo -e "${GREEN}${BOLD}✓${NC} $1"; }
warn()    { echo -e "${YELLOW}${BOLD}warning${NC} $1"; }
error()   { echo -e "${RED}${BOLD}error${NC} $1" >&2; }
dim()     { echo -e "${DIM}$1${NC}"; }

usage() {
    echo "Usage: $0 <plugin>/<version> [<plugin>/<version> ...]"
    echo ""
    echo "Tags and pushes one plugin release per push, then verifies each one"
    echo "actually started a workflow run."
    echo ""
    echo "Environment variables:"
    echo "  EOS_PLUGIN_RUN_TIMEOUT        Seconds to wait for a run (default: 90)"
    echo "  EOS_PLUGIN_RUN_POLL_INTERVAL  Seconds between polls (default: 5)"
    echo ""
    echo "Examples:"
    echo "  $0 eos-sink-loki/v0.1.0"
    echo "  $0 eos-sink-logbench/v0.1.0 eos-sink-loki/v0.1.0 eos-sink-otlp/v0.1.0 eos-sink-sse/v0.1.0"
}

# validate_tag rejects anything the release workflow's tag pattern
# ("eos-sink-*/v*") would not match, since such a tag pushes cleanly and then
# sits there having triggered nothing -- the same silent failure this script
# exists to prevent.
validate_tag() {
    local tag="$1"
    case "$tag" in
        eos-sink-*/v*) ;;
        *)
            error "Not a release tag: ${tag}"
            dim "  Expected <plugin>/<version>, e.g. eos-sink-loki/v0.1.0"
            return 1
            ;;
    esac

    local plugin="${tag%%/*}" version="${tag#*/}"
    if [ -z "${plugin#eos-sink-}" ]; then
        error "Missing plugin name: ${tag}"
        return 1
    fi
    # A "version" containing a slash means the tag has more than two segments,
    # which the workflow's own ${TAG##*/} parse would silently truncate.
    case "$version" in
        */*)
            error "Too many path segments: ${tag}"
            dim "  Expected exactly <plugin>/<version>"
            return 1
            ;;
    esac
}

# dispatch_hint prints the workflow_dispatch invocation that publishes a tag
# whose push produced no run. The workflow accepts plugin and version as
# inputs precisely so this path exists.
dispatch_hint() {
    local tag="$1"
    echo "gh workflow run ${WORKFLOW} -f plugin=${tag%%/*} -f version=${tag#*/}"
}

# run_exists_for reports whether the release workflow has a run for $tag.
# Tag pushes report the tag as the run's headBranch, which is the only field
# that ties a run back to the ref that started it without fetching each run.
run_exists_for() {
    local tag="$1"
    gh run list --workflow "$WORKFLOW" --limit 50 --json headBranch \
        --jq '.[].headBranch' 2>/dev/null | grep -Fxq "$tag"
}

# wait_for_run polls until the run for $tag shows up or the timeout elapses.
wait_for_run() {
    local tag="$1"
    local waited=0

    while [ "$waited" -lt "$RUN_TIMEOUT" ]; do
        if run_exists_for "$tag"; then
            return 0
        fi
        sleep "$RUN_POLL_INTERVAL"
        waited=$((waited + RUN_POLL_INTERVAL))
    done

    run_exists_for "$tag"
}

# push_tag creates the tag if it doesn't exist locally and pushes it alone.
# One ref per push is the whole point: batching four of them is what makes
# GitHub drop the events.
push_tag() {
    local tag="$1"

    if ! git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
        git tag "$tag"
        dim "  Created tag ${tag}"
    fi

    git push origin "$tag"
}

# release_tag takes one tag from creation to a confirmed workflow run.
release_tag() {
    local tag="$1"

    info "Releasing ${BOLD}${tag}${NC}"
    push_tag "$tag" || { error "Failed to push ${tag}"; return 1; }

    if wait_for_run "$tag"; then
        success "Workflow run started for ${tag}"
        return 0
    fi

    error "No workflow run appeared for ${tag} within ${RUN_TIMEOUT}s"
    dim "  The tag was pushed, so this is not the >3-tags-per-push rule."
    dim "  Check that Actions is enabled and ${WORKFLOW} still matches the tag pattern."
    dim "  Publish it directly with:"
    dim "    $(dispatch_hint "$tag")"
    return 1
}

check_prerequisites() {
    if ! command -v gh >/dev/null 2>&1; then
        error "gh is required to verify that each tag started a workflow run"
        dim "  Install it from https://cli.github.com, or push tags one at a time by hand"
        exit 1
    fi

    if ! gh auth status >/dev/null 2>&1; then
        error "gh is not authenticated"
        dim "  Run: gh auth login"
        exit 1
    fi
}

main() {
    if [ $# -eq 0 ]; then
        usage
        exit 1
    fi

    case "${1:-}" in
        --help|-h) usage; exit 0 ;;
    esac

    # Every tag is validated before any of them is pushed: a typo in the last
    # argument should not leave the first three plugins released.
    local tag
    for tag in "$@"; do
        validate_tag "$tag" || exit 1
    done

    check_prerequisites

    local failed=()
    for tag in "$@"; do
        release_tag "$tag" || failed+=("$tag")
    done

    echo ""
    if [ ${#failed[@]} -eq 0 ]; then
        success "All ${#} release(s) pushed and confirmed"
        return 0
    fi

    error "${#failed[@]} of ${#} release(s) started no workflow run:"
    for tag in "${failed[@]}"; do
        dim "  ${tag} -> $(dispatch_hint "$tag")"
    done
    return 1
}

# Only run main when executed directly, so the tests can source this file and
# call its functions in isolation.
if [[ "${BASH_SOURCE[0]:-${0}}" == "${0}" ]]; then
    main "$@"
fi
