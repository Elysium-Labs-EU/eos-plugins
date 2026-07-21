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

fetch_latest_version() {
    local plugin="$1" tool="$2"
    local url="${GITHUB_API_URL}/repos/${REPO}/releases?per_page=20"
    local response
    if [ "$tool" = "curl" ]; then
        response=$(curl -fsSL "$url")
    else
        response=$(wget -qO- "$url")
    fi
    # Find first release tag matching <plugin>/v*
    echo "$response" | grep -o "\"tag_name\":\"${plugin}/v[^\"]*\"" | head -1 | sed -E 's/"tag_name":"[^/]+\/([^"]+)"/\1/'
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
    local tmp_binary="/tmp/${plugin}"
    local tmp_checksums="/tmp/${plugin}_sha256sums.txt"

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
        rm -f "$tmp_binary" "$tmp_checksums"
        exit 1
    fi
    rm -f "$tmp_checksums"
    success "Checksum verified"

    step "Installing binary..."
    mkdir -p "$INSTALL_DIR"
    chmod +x "$tmp_binary"
    cp "$tmp_binary" "${INSTALL_DIR}/${plugin}"
    rm -f "$tmp_binary"
    success "Installed to ${INSTALL_DIR}/${plugin}"

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
}

main "$@"
