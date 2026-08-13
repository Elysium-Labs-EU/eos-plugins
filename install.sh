#!/bin/bash
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

readonly REPO="Elysium-Labs-EU/eos-plugins"
readonly GITHUB_URL="https://github.com"
readonly GITHUB_API_URL="https://api.github.com"
readonly INSTALL_DIR="${EOS_PLUGIN_INSTALL_DIR:-/usr/local/bin}"

AUTO_YES=false

info()    { echo -e "${BLUE}${BOLD}info${NC} $1"; }
success() { echo -e "${GREEN}${BOLD}✓${NC} $1"; }
warn()    { echo -e "${YELLOW}${BOLD}warning${NC} $1"; }
error()   { echo -e "${RED}${BOLD}error${NC} $1" >&2; }
step()    { echo -e "\n${CYAN}${BOLD}→${NC} $1"; }
dim()     { echo -e "${DIM}$1${NC}"; }

usage() {
    echo "Usage: $0 [OPTIONS] <plugin>"
    echo ""
    echo "Arguments:"
    echo "  plugin    Plugin name: any eos-sink-<name> with a published release"
    echo "            (see the repo README for available plugins)"
    echo ""
    echo "Options:"
    echo "  --yes, -y           Skip confirmation prompts"
    echo "  --help              Show this help message"
    echo ""
    echo "Environment variables:"
    echo "  EOS_PLUGIN_INSTALL_DIR   Install directory (default: /usr/local/bin)"
    echo "  EOS_PLUGIN_VERSION       Version to install (default: latest)"
    echo ""
    echo "Examples:"
    echo "  curl -sSL https://raw.githubusercontent.com/${REPO}/main/install.sh | sudo bash -s -- eos-sink-loki"
    echo "  sudo bash install.sh eos-sink-sse"
}

confirm() {
    local prompt="$1"
    local default="${2:-n}"
    if [ "$AUTO_YES" = true ]; then
        [[ "$default" =~ ^[Yy]$ ]]; return $?
    fi
    local response
    [ "$default" = "y" ] && prompt="$prompt [Y/n]" || prompt="$prompt [y/N]"
    echo -ne "${YELLOW}?${NC} $prompt "
    read -r response
    response=${response:-$default}
    [[ "$response" =~ ^[Yy]$ ]]
}

check_root() {
    if [ $EUID -ne 0 ]; then
        error "This script must be run as root"
        dim "  Try: sudo $0 <plugin>"
        exit 1
    fi
}

# check_eos_present warns (does not block) if eos itself isn't on PATH -- a
# sink plugin has nothing to run under without it.
check_eos_present() {
    if ! command -v eos &>/dev/null; then
        warn "eos was not found on PATH"
        dim "  A sink plugin is useless without eos managing it: https://github.com/Elysium-Labs-EU/eos#install"
    fi
}

detect_arch() {
    case $(uname -m) in
        x86_64)       echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)
            error "Unsupported architecture: $(uname -m)"
            dim "  Supported: x86_64, aarch64/arm64"
            exit 1
            ;;
    esac
}

detect_download_tool() {
    if command -v curl &>/dev/null; then echo "curl"
    elif command -v wget &>/dev/null; then echo "wget"
    else
        error "Neither curl nor wget is installed"
        exit 1
    fi
}

download_file() {
    local url="$1" output="$2" tool="$3"
    if [ "$tool" = "curl" ]; then
        curl -fsSL -o "$output" "$url"
    else
        wget -qO "$output" "$url"
    fi
}

# extract_release_pairs prints one "<prerelease> <tag_name>" line per release
# from a /releases list JSON blob on stdin. Both fields are release-level only
# (neither appears in the nested assets array), so a flat grep of each yields
# two lists that pair up 1:1 in list order.
extract_release_pairs() {
    local json scratch
    json="$(cat)"
    scratch="$(mktemp -d)"
    printf '%s' "$json" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*"([^"]+)"$/\1/' >"$scratch/tags"
    printf '%s' "$json" | grep -o '"prerelease"[[:space:]]*:[[:space:]]*[a-z]*' | sed -E 's/.*:[[:space:]]*//' >"$scratch/prerelease"
    paste -d ' ' "$scratch/prerelease" "$scratch/tags"
    rm -rf "$scratch"
}

# select_plugin_version prints the newest version for $plugin from a /releases
# list JSON blob on stdin, with the "<plugin>/" tag prefix stripped.
#
# One repo publishes tags for several plugins, so the list is filtered to the
# requested plugin before any version comparison; an unfiltered "newest
# release" would routinely belong to a different plugin.
#
# Stable releases win over prereleases outright rather than by sort order:
# sort -V places a bare "v0.1.0" before "v0.1.0-rc.9", the opposite of semver
# precedence, so sorting the combined list would return a prerelease as
# newest. List position is not trusted either; the releases list is
# documented newest-first but has been observed returning a freshly
# published release out of order.
select_plugin_version() {
    local plugin="$1" pairs stable
    pairs="$(extract_release_pairs)"
    stable=$(printf '%s\n' "$pairs" | awk -v p="^${plugin}/v" '$1 == "false" && $2 ~ p { print $2 }' | sed "s|^${plugin}/||" | sort -V | tail -1)
    if [ -n "$stable" ]; then
        printf '%s' "$stable"
        return
    fi
    printf '%s\n' "$pairs" | awk -v p="^${plugin}/v" '$2 ~ p { print $2 }' | sed "s|^${plugin}/||" | sort -V | tail -1
}

# fetch_latest_version resolves the newest published version for $plugin.
# It scans the full releases list rather than /releases/latest, which answers
# for the repo as a whole and so usually names some other plugin's release.
fetch_latest_version() {
    local plugin="$1" tool="$2"
    local api_base="${EOS_PLUGIN_API_BASE:-${GITHUB_API_URL}/repos/${REPO}}"
    local url="${api_base}/releases?per_page=100"
    local response
    if [ "$tool" = "curl" ]; then
        response=$(curl -fsSL "$url") || return 1
    else
        response=$(wget -qO- "$url") || return 1
    fi
    printf '%s' "$response" | select_plugin_version "$plugin"
}

main() {
    local plugin=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y) AUTO_YES=true; shift ;;
            --help|-h) usage; exit 0 ;;
            eos-sink-*) plugin="$1"; shift ;;
            *) error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    if [ -z "$plugin" ]; then
        error "Plugin name required"
        echo ""
        usage
        exit 1
    fi

    echo ""
    echo -e "${BOLD}eos plugin installer${NC}"
    echo ""

    local download_tool
    download_tool=$(detect_download_tool)

    local version="${EOS_PLUGIN_VERSION:-}"
    if [ -z "$version" ]; then
        step "Fetching latest version for ${plugin}..."
        version=$(fetch_latest_version "$plugin" "$download_tool")
        if [ -z "$version" ]; then
            error "Failed to fetch latest version for ${plugin}"
            dim "  Is \"${plugin}\" spelled correctly and published at github.com/${REPO}?"
            dim "  Set EOS_PLUGIN_VERSION to specify manually"
            exit 1
        fi
        info "Latest version: ${BOLD}${version}${NC}"
    else
        info "Using version: ${BOLD}${version}${NC}"
    fi

    info "Running pre-flight checks..."
    check_root
    check_eos_present

    local arch
    arch=$(detect_arch)
    dim "  Plugin:       $plugin"
    dim "  Architecture: $arch"
    dim "  Download tool: $download_tool"

    echo ""
    echo -e "${BOLD}Installation plan:${NC}"
    echo "  1. Download ${plugin}-linux-${arch} (${version})"
    echo "  2. Verify SHA256 checksum"
    echo "  3. Install to ${INSTALL_DIR}/${plugin}"
    echo ""

    if ! confirm "Continue?" "y"; then
        info "Installation cancelled"
        exit 0
    fi

    local tag="${plugin}/${version}"
    local base_url="${GITHUB_URL}/${REPO}/releases/download/${tag}"
    local artifact="${plugin}-linux-${arch}"

    # A predictable /tmp path is a symlink-attack surface when this script
    # runs as root: a local user could pre-create it pointing elsewhere
    # before root runs the installer. mktemp -d plus a private dir sidesteps
    # that; the trap guarantees cleanup on any exit path, including the
    # error returns below.
    #
    # tmp_dir is deliberately NOT `local`: an EXIT trap runs after the
    # function that registered it has already returned, in the top-level
    # script scope -- a `local` binding from inside main() is torn down by
    # then, so the trap would see an empty/undefined variable and silently
    # no-op instead of cleaning up (confirmed live; this is why the fixed
    # /tmp path this replaces never had a working cleanup path either).
    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/eos-plugin-install.XXXXXXXX")" || { error "Failed to create secure temp dir"; exit 1; }
    trap 'rm -rf "${tmp_dir:-}"' EXIT
    local tmp_binary="${tmp_dir}/${plugin}"
    local tmp_checksums="${tmp_dir}/sha256sums.txt"

    step "Downloading ${artifact}..."
    if ! download_file "${base_url}/${artifact}" "$tmp_binary" "$download_tool"; then
        error "Download failed"
        dim "  URL: ${base_url}/${artifact}"
        exit 1
    fi
    success "Downloaded"

    step "Verifying checksum..."
    if ! download_file "${base_url}/sha256sums.txt" "$tmp_checksums" "$download_tool"; then
        error "Failed to download sha256sums.txt"
        exit 1
    fi

    local expected actual
    expected=$(grep "  ${artifact}$" "$tmp_checksums" | awk '{print $1}')
    if [ -z "$expected" ]; then
        error "No checksum found for ${artifact}"
        exit 1
    fi
    actual=$(sha256sum "$tmp_binary" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
        error "Checksum mismatch; binary may be corrupted"
        dim "  expected: $expected"
        dim "  got:      $actual"
        exit 1
    fi
    success "Checksum verified"

    step "Installing binary..."
    mkdir -p "$INSTALL_DIR"
    chmod +x "$tmp_binary"
    local final_binary="${INSTALL_DIR}/${plugin}"
    mv -f "$tmp_binary" "$final_binary"
    success "Installed to ${final_binary}"

    if ! command -v "$plugin" &>/dev/null; then
        warn "${INSTALL_DIR} does not appear to be on PATH"
        dim "  eos resolves sink plugins by looking up eos-sink-<type> on PATH -- add it:"
        dim "    export PATH=\"${INSTALL_DIR}:\$PATH\""
    fi

    echo ""
    echo -e "${GREEN}${BOLD}Done!${NC} ${plugin} ${version} installed."
    echo ""
    dim "Add to service.yaml:"
    echo -e "  ${CYAN}log_sinks:${NC}"
    case "$plugin" in
        eos-sink-loki)
            echo -e "  ${CYAN}  - type: loki${NC}"
            echo -e "  ${CYAN}    mode: push${NC}"
            echo -e "  ${CYAN}    address: \"http://localhost:3100\"${NC}"
            ;;
        eos-sink-sse)
            echo -e "  ${CYAN}  - type: sse${NC}"
            echo -e "  ${CYAN}    mode: serve${NC}"
            echo -e "  ${CYAN}    address: \":9000\"${NC}"
            ;;
        eos-sink-logbench)
            echo -e "  ${CYAN}  - type: logbench${NC}"
            echo -e "  ${CYAN}    mode: push${NC}"
            echo -e "  ${CYAN}    address: \"http://localhost:1447\"${NC}"
            echo -e "  ${CYAN}    options:${NC}"
            echo -e "  ${CYAN}      project_id: \"your-project-id\"${NC}"
            ;;
        *)
            echo -e "  ${CYAN}  - type: ${plugin#eos-sink-}${NC}"
            echo -e "  ${CYAN}    mode: push${NC}"
            echo -e "  ${CYAN}    address: \"<sink-address>\"${NC}"
            ;;
    esac
    echo ""
    dim "Full option reference (streams, buffer_size, restart_delay_ms, exec, args, named sinks):"
    dim "  https://github.com/${REPO}#configuration"
    echo ""
}

# Only run main when this file is executed directly, not when tests `source`
# it to call its helper functions (e.g. select_plugin_version) in isolation.
if [[ "${BASH_SOURCE[0]:-${0}}" == "${0}" ]]; then
    main "$@"
fi
