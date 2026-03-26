#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
#  Claude Code Installer — ProjectAILeap
#  https://github.com/ProjectAILeap/claude-code-installer
#
#  Binary source: https://github.com/ProjectAILeap/claude-code-releases
#  Supports: macOS (arm64/x64)、Linux (x64/arm64/musl)
#  Features:  Install / Upgrade / GitHub mirror acceleration
# ════════════════════════════════════════════════════════════════════════════
set -euo pipefail

RELEASES_REPO="ProjectAILeap/claude-code-releases"
DATA_DIR="${HOME}/.local/share/claude-code"
VERSION_FILE="${DATA_DIR}/version"

# ── Colors ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

info()    { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
ok()      { printf "${GREEN}[ OK ]${NC}  %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()     { printf "${RED}[ERR ]${NC}  %s\n" "$*" >&2; }
step()    { printf "\n${BOLD}${CYAN}▶ %s${NC}\n" "$*"; }
die()     { err "$*"; exit 1; }

# ── Detect platform ──────────────────────────────────────────────────────────
detect_platform() {
    local os arch libc=""
    os="$(uname -s)"
    arch="$(uname -m)"

    # Detect musl libc (Alpine, etc.)
    if ldd --version 2>&1 | grep -qi musl 2>/dev/null; then
        libc="-musl"
    fi

    case "$os" in
        Darwin)
            case "$arch" in
                arm64)  PLATFORM="darwin-arm64" ;;
                x86_64) PLATFORM="darwin-x64" ;;
                *) die "Unsupported macOS architecture: $arch" ;;
            esac
            ;;
        Linux)
            case "$arch" in
                x86_64)        PLATFORM="linux-x64${libc}" ;;
                aarch64|arm64) PLATFORM="linux-arm64${libc}" ;;
                *) die "Unsupported Linux architecture: $arch" ;;
            esac
            ;;
        *)
            die "Unsupported OS: $os. This script supports macOS and Linux only."
            ;;
    esac

    info "Platform: ${PLATFORM}"
}

# ── Install directory ────────────────────────────────────────────────────────
detect_install_dir() {
    if [[ "${PLATFORM}" == darwin-* ]]; then
        if [[ -w "/usr/local/bin" ]]; then
            INSTALL_DIR="/usr/local/bin"
        else
            INSTALL_DIR="${HOME}/.local/bin"
        fi
    else
        INSTALL_DIR="${HOME}/.local/bin"
    fi
    mkdir -p "${INSTALL_DIR}"
    info "Install dir: ${INSTALL_DIR}"
}

# ── Mirror selection ─────────────────────────────────────────────────────────
# Each entry is a URL base that, when appended with /owner/repo/..., forms a valid download URL.
# Prefix-proxy mirrors use: https://proxy.example.com/https://github.com/<path>
# Domain-replacement mirrors use: https://mirror.example.com/<path>
MIRRORS=(
    "https://github.com"
    "https://ghfast.top/https://github.com"
    "https://gh-proxy.com/https://github.com"
    "https://mirror.ghproxy.com/https://github.com"
    "https://kkgithub.com"
)

SELECTED_MIRROR=""

select_mirror() {
    step "Selecting fastest mirror..."
    local test_path="/${RELEASES_REPO}/releases"

    for m in "${MIRRORS[@]}"; do
        local url="${m}${test_path}"
        if curl -sI --connect-timeout 8 --max-time 10 "$url" &>/dev/null; then
            SELECTED_MIRROR="$m"
            if [[ "$m" == "https://github.com" ]]; then
                ok "Direct: github.com"
            else
                ok "Mirror: $m"
            fi
            return
        fi
        info "  Unreachable: $m"
    done

    die "All mirrors failed. Please check your network connection."
}

make_download_url() {
    # $1 = path starting with /owner/repo/...
    printf "%s%s" "${SELECTED_MIRROR}" "$1"
}

# ── Fetch latest version ─────────────────────────────────────────────────────
get_latest_version() {
    step "Fetching latest version..."
    local api_url="https://api.github.com/repos/${RELEASES_REPO}/releases/latest"
    local response

    response="$(curl -sf --connect-timeout 8 --max-time 15 \
        -H "Accept: application/vnd.github.v3+json" \
        "$api_url" 2>/dev/null || true)"

    if [[ -n "$response" ]]; then
        VERSION="$(printf '%s' "$response" | grep '"tag_name"' | head -1 | \
            sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/')"
    fi

    # Fallback: parse Location header from kkgithub redirect
    if [[ -z "${VERSION:-}" ]]; then
        info "GitHub API unavailable, trying fallback..."
        local location
        location="$(curl -sI --connect-timeout 8 --max-time 12 \
            "https://kkgithub.com/${RELEASES_REPO}/releases/latest" 2>/dev/null | \
            grep -i '^location:' | tr -d '\r' | awk '{print $2}')"
        VERSION="$(printf '%s' "$location" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    fi

    [[ -n "${VERSION:-}" ]] || die "Cannot determine latest version. Check network."
    info "Latest: v${VERSION}"
}

# ── Version check ────────────────────────────────────────────────────────────
check_installed_version() {
    INSTALLED_VERSION=""
    if [[ -f "$VERSION_FILE" ]]; then
        INSTALLED_VERSION="$(cat "$VERSION_FILE" | tr -d '[:space:]')"
    fi

    if [[ -n "$INSTALLED_VERSION" ]]; then
        if [[ "$INSTALLED_VERSION" == "$VERSION" ]]; then
            ok "Claude Code v${VERSION} is already up to date."
            # Still offer to reinstall if binary is missing
            if command -v claude &>/dev/null || [[ -x "${INSTALL_DIR}/claude" ]]; then
                exit 0
            fi
            info "Binary missing, reinstalling..."
        else
            info "Upgrading: v${INSTALLED_VERSION} → v${VERSION}"
        fi
    else
        info "Installing Claude Code v${VERSION}"
    fi
}

# ── Download & verify ────────────────────────────────────────────────────────
download_and_verify() {
    step "Downloading claude-${VERSION}-${PLATFORM}..."

    local filename="claude-${VERSION}-${PLATFORM}"
    local dl_url
    local ck_url
    dl_url="$(make_download_url "/${RELEASES_REPO}/releases/download/v${VERSION}/${filename}")"
    ck_url="$(make_download_url "/${RELEASES_REPO}/releases/download/v${VERSION}/sha256sums.txt")"

    TMP_DIR="$(mktemp -d)"
    # Always clean up temp dir on exit
    trap 'rm -rf "${TMP_DIR}"' EXIT

    local bin_file="${TMP_DIR}/${filename}"
    local ck_file="${TMP_DIR}/sha256sums.txt"

    info "URL: ${dl_url}"
    if ! curl -fL --connect-timeout 30 --max-time 300 \
         --progress-bar -o "${bin_file}" "${dl_url}"; then
        die "Download failed. Try a different mirror or check your connection."
    fi

    # Checksum verification
    if curl -fsSL --connect-timeout 15 --max-time 30 \
         -o "${ck_file}" "${ck_url}" 2>/dev/null; then
        local expected actual
        expected="$(grep -F "${filename}" "${ck_file}" | awk '{print $1}')"
        if [[ -n "$expected" ]]; then
            if command -v sha256sum &>/dev/null; then
                actual="$(sha256sum "${bin_file}" | awk '{print $1}')"
            elif command -v shasum &>/dev/null; then
                actual="$(shasum -a 256 "${bin_file}" | awk '{print $1}')"
            else
                warn "No sha256sum or shasum found, skipping checksum."
                actual="$expected"
            fi

            if [[ "$actual" == "$expected" ]]; then
                ok "SHA-256 verified."
            else
                err "Checksum mismatch!"
                err "  Expected: ${expected}"
                err "  Got:      ${actual}"
                die "The downloaded file may be corrupted."
            fi
        else
            warn "No checksum entry for ${filename}, skipping."
        fi
    else
        warn "Could not download checksums, skipping verification."
    fi

    BINARY_FILE="${bin_file}"
}

# ── Install ───────────────────────────────────────────────────────────────────
install_binary() {
    step "Installing..."
    chmod +x "${BINARY_FILE}"

    # Replace existing binary (use mv for atomic replace)
    local dest="${INSTALL_DIR}/claude"
    if [[ -f "$dest" ]]; then
        rm -f "${dest}.old" 2>/dev/null || true
        mv "$dest" "${dest}.old" 2>/dev/null || true
    fi
    cp "${BINARY_FILE}" "$dest"
    rm -f "${dest}.old" 2>/dev/null || true

    mkdir -p "${DATA_DIR}"
    printf '%s\n' "${VERSION}" > "${VERSION_FILE}"

    ok "Installed: ${dest}"
}

# ── PATH setup ────────────────────────────────────────────────────────────────
setup_path() {
    if printf '%s\n' "${PATH//:/$'\n'}" | grep -qx "${INSTALL_DIR}"; then
        return
    fi

    step "Adding ${INSTALL_DIR} to PATH..."
    local export_line="export PATH=\"${INSTALL_DIR}:\$PATH\""
    local added=false

    for rc in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile"; do
        if [[ -f "$rc" ]] && ! grep -qF "${INSTALL_DIR}" "$rc"; then
            {
                printf '\n# Added by claude-code-installer\n'
                printf '%s\n' "$export_line"
            } >> "$rc"
            info "  Updated: $rc"
            added=true
        fi
    done

    if $added; then
        warn "Restart your shell or run: source ~/.bashrc  (or ~/.zshrc)"
    else
        warn "Add this to your shell profile:"
        warn "  ${export_line}"
    fi
}

# ── Optional CC Switch ────────────────────────────────────────────────────────
install_cc_switch_prompt() {
    # Skip in non-interactive mode (piped stdin)
    [ -t 0 ] || return

    printf "\n${BOLD}Install CC Switch (API Provider switcher)?${NC} [y/N] "
    read -r reply </dev/tty || return
    [[ "$reply" =~ ^[Yy] ]] || return

    warn "CC Switch currently only provides Windows MSI packages."
    info "Download: https://github.com/farion1231/cc-switch/releases"
}

# ── Final message ─────────────────────────────────────────────────────────────
print_done() {
    printf "\n"
    printf "${GREEN}${BOLD}  ✓ Claude Code v%s installed!${NC}\n\n" "${VERSION}"
    printf "  Quick start:\n"
    printf "    ${BOLD}claude${NC}            — start Claude Code\n"
    printf "    ${BOLD}claude --version${NC}  — verify installation\n"
    printf "\n"
    printf "  To upgrade later, re-run this installer.\n"
    printf "  To uninstall: run uninstall.sh\n\n"

    if ! printf '%s\n' "${PATH//:/$'\n'}" | grep -qx "${INSTALL_DIR}"; then
        printf "${YELLOW}  Restart your shell to use 'claude' command.${NC}\n\n"
    fi
}

# ── Entry point ───────────────────────────────────────────────────────────────
main() {
    printf "\n${BOLD}${CYAN}━━━ Claude Code Installer ━━━${NC}  ProjectAILeap\n"
    printf "Source: github.com/ProjectAILeap/claude-code-releases\n\n"

    detect_platform
    detect_install_dir
    get_latest_version
    check_installed_version
    select_mirror
    download_and_verify
    install_binary
    setup_path
    install_cc_switch_prompt
    print_done
}

main "$@"
