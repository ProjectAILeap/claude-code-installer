#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
#  Claude Code Installer — ProjectAILeap
#  https://github.com/ProjectAILeap/claude-code-installer
#
#  Binary source: https://github.com/ProjectAILeap/claude-code-releases
#                 https://storage.googleapis.com (official Anthropic GCS)
#  Supports: macOS (arm64/x64)、Linux (x64/arm64/musl)
#  Features:  Install / Upgrade / Mirror acceleration / CC Switch
#
#  Usage: bash install.sh [stable|latest|VERSION]
# ════════════════════════════════════════════════════════════════════════════
# shellcheck disable=SC2059  # color variables in printf format strings are intentional
set -euo pipefail

# ── Target parameter (passed through to claude install) ───────────────────
TARGET="${1:-}"
if [[ -n "$TARGET" ]] && [[ ! "$TARGET" =~ ^(stable|latest|[0-9]+\.[0-9]+\.[0-9]+(-[^[:space:]]+)?)$ ]]; then
    echo "Usage: $0 [stable|latest|VERSION]" >&2
    exit 1
fi

RELEASES_REPO="ProjectAILeap/claude-code-releases"
CC_SWITCH_REPO="farion1231/cc-switch"
GCS_BUCKET="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
DOWNLOAD_DIR="${HOME}/.claude/downloads"
DATA_DIR="${HOME}/.local/share/claude-code"
VERSION_FILE="${DATA_DIR}/version"
CLAUDE_JSON="${HOME}/.claude.json"
CC_SWITCH_INSTALLED=false
INSTALL_DIR=""      # set by detect_install_dir, used only in fallback
MIRROR_ORDER=()  # all reachable sources sorted by latency (GCS + GitHub)
GITHUB_MIRROR="" # fastest GitHub mirror (CC Switch only)

# ── Colors ────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

info()  { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[ OK ]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()   { printf "${RED}[ERR ]${NC}  %s\n" "$*" >&2; }
step()  { printf "\n${BOLD}${CYAN}▶ %s${NC}\n" "$*"; }
die()   { err "$*"; exit 1; }

# ── Millisecond timer (cross-platform: python3 or date fallback) ──────────
_now_ms() {
    python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null \
        || echo $(($(date +%s) * 1000))
}

# ── Detect platform ───────────────────────────────────────────────────────
detect_platform() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"

    case "$os" in
        Darwin)
            # Rosetta 2: shell running as x64 on an ARM Mac — use native arm64 binary
            if [[ "$arch" = "x86_64" ]] && [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ]]; then
                arch="arm64"
            fi
            case "$arch" in
                arm64)  PLATFORM="darwin-arm64" ;;
                x86_64) PLATFORM="darwin-x64" ;;
                *) die "Unsupported macOS architecture: $arch" ;;
            esac
            ;;
        Linux)
            # musl detection: check library files and ldd output
            local libc=""
            if [ -f /lib/libc.musl-x86_64.so.1 ] || [ -f /lib/libc.musl-aarch64.so.1 ] || \
               ldd /bin/ls 2>&1 | grep -q musl 2>/dev/null; then
                libc="-musl"
            fi
            case "$arch" in
                x86_64)        PLATFORM="linux-x64${libc}" ;;
                aarch64|arm64) PLATFORM="linux-arm64${libc}" ;;
                *) die "Unsupported Linux architecture: $arch" ;;
            esac
            ;;
        MINGW*|MSYS*|CYGWIN*)
            die "Windows is not supported by this script. Use install.ps1 instead."
            ;;
        *)
            die "Unsupported OS: $os"
            ;;
    esac

    info "Platform: ${PLATFORM}"
}

# ── Install directory (used only in fallback) ─────────────────────────────
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

# ── Mirror selection (concurrent speed test) ──────────────────────────────
MIRRORS=(
    "https://github.com"
    "https://ghfast.top/https://github.com"
    "https://gh-proxy.com/https://github.com"
    "https://mirror.ghproxy.com/https://github.com"
    "https://kkgithub.com"
)

_mirror_label() {
    local m="$1"
    case "$m" in
        "$GCS_BUCKET")        printf "GCS (Anthropic)" ;;
        "https://github.com") printf "github.com" ;;
        *)                    printf '%s' "$m" | sed 's|https://\([^/]*\).*|\1|' ;;
    esac
}

select_mirror() {
    step "Testing mirrors..."
    local result_dir
    result_dir="$(mktemp -d)"

    # Launch concurrent probes for GCS + all GitHub mirrors
    local all_sources=("$GCS_BUCKET" "${MIRRORS[@]}")
    local m
    for m in "${all_sources[@]}"; do
        (
            local test_url
            if [[ "$m" == "$GCS_BUCKET" ]]; then
                test_url="${m}/${VERSION}/manifest.json"
            else
                # Test with actual release asset (~750 bytes) using GET —
                # HEAD requests are often rejected by proxy mirrors.
                # This tests the exact URL pattern used for binary downloads.
                test_url="${m}/${RELEASES_REPO}/releases/download/v${VERSION}/sha256sums.txt"
            fi
            local t0 t1 ms
            t0="$(_now_ms)"
            if curl -sfL --connect-timeout 8 --max-time 10 -o /dev/null "$test_url" &>/dev/null; then
                t1="$(_now_ms)"
                ms=$((t1 - t0))
                printf '%s\n' "$m" > "${result_dir}/$(printf '%06d' "$ms")_${RANDOM}"
            fi
        ) &
    done
    wait  # all probes finish within --max-time 10s

    # Collect results sorted by latency into MIRROR_ORDER
    MIRROR_ORDER=()
    GITHUB_MIRROR=""
    local f mirror ms
    # shellcheck disable=SC2012  # filenames are digits+underscore, ls is safe here
    while IFS= read -r f; do
        mirror="$(cat "${result_dir}/${f}")"
        ms="${f%%_*}"
        ms=$((10#$ms))
        info "  $(_mirror_label "$mirror"): ${ms}ms"
        MIRROR_ORDER+=("$mirror")
        [[ -z "$GITHUB_MIRROR" ]] && [[ "$mirror" != "$GCS_BUCKET" ]] && GITHUB_MIRROR="$mirror"
    done < <(ls "${result_dir}" 2>/dev/null | sort)

    rm -rf "${result_dir}"

    [[ ${#MIRROR_ORDER[@]} -gt 0 ]] || die "All mirrors failed. Please check your network connection."
    [[ -n "$GITHUB_MIRROR" ]] || GITHUB_MIRROR="https://github.com"

    ok "Best: $(_mirror_label "${MIRROR_ORDER[0]}")"
}

# make_download_url always uses a GitHub mirror (CC Switch, fallback paths)
make_download_url() {
    printf "%s%s" "${GITHUB_MIRROR}" "$1"
}

# ── Fetch latest version ──────────────────────────────────────────────────
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

# ── Version check ─────────────────────────────────────────────────────────
check_installed_version() {
    INSTALLED_VERSION=""

    if command -v claude &>/dev/null; then
        local out
        out="$(claude --version 2>&1 || true)"
        if [[ "$out" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
            INSTALLED_VERSION="${BASH_REMATCH[1]}"
        fi
    fi

    if [[ "$INSTALLED_VERSION" == "$VERSION" ]]; then
        ok "Claude Code v${VERSION} is already up to date."
        exit 0
    fi

    if [[ -n "$INSTALLED_VERSION" ]]; then
        info "Upgrading: v${INSTALLED_VERSION} → v${VERSION}"
    else
        info "Installing Claude Code v${VERSION}"
    fi
}

# ── Git check (Linux only; macOS auto-prompts via Xcode CLT) ─────────────
check_git() {
    if [[ "${PLATFORM}" == darwin-* ]]; then
        return
    fi

    if command -v git &>/dev/null; then
        local git_ver
        git_ver="$(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        ok "Git ${git_ver} found."
        return
    fi

    warn "Git is not installed. Claude Code requires Git."
    printf "\n  Install Git with your package manager:\n"
    printf "    Debian/Ubuntu:  sudo apt install git\n"
    printf "    RHEL/Fedora:    sudo yum install git  (or dnf install git)\n"
    printf "    Arch:           sudo pacman -S git\n"
    printf "    Alpine:         sudo apk add git\n\n"
    printf "  Install Git first, then re-run this installer.\n\n"
    printf "  Continue without Git? [y/N] "

    local reply="n"
    [ -t 0 ] && read -r reply </dev/tty || reply="n"
    if [[ ! "$reply" =~ ^[Yy] ]]; then
        exit 1
    fi
    warn "Continuing without Git — some Claude Code features may not work."
}

# ── Checksum verification via manifest.json ───────────────────────────────
# Both GCS and GitHub releases use the same manifest.json format:
#   { "platforms": { "PLATFORM": { "checksum": "HEX64", ... } } }
_verify_from_manifest() {
    local bin_file="$1" manifest_url="$2"

    local manifest
    manifest="$(curl -fsSL --connect-timeout 15 --max-time 30 "$manifest_url" 2>/dev/null || true)"
    if [[ -z "$manifest" ]]; then
        warn "Could not download manifest.json, skipping verification."
        return
    fi

    local checksum=""
    # [^}]* matches across newlines (anything that's not a closing brace)
    if [[ "$manifest" =~ \"${PLATFORM}\"[^}]*\"checksum\"[[:space:]]*:[[:space:]]*\"([a-f0-9]{64})\" ]]; then
        checksum="${BASH_REMATCH[1]}"
    fi

    if [[ -z "$checksum" ]]; then
        warn "No checksum found for ${PLATFORM} in manifest.json, skipping."
        return
    fi

    local actual
    if command -v sha256sum &>/dev/null; then
        actual="$(sha256sum "$bin_file" | awk '{print $1}')"
    elif command -v shasum &>/dev/null; then
        actual="$(shasum -a 256 "$bin_file" | awk '{print $1}')"
    else
        warn "No sha256sum/shasum found, skipping checksum."
        return
    fi

    if [[ "$actual" == "$checksum" ]]; then
        ok "SHA-256 verified."
    else
        err "Checksum mismatch!  Expected: ${checksum}  Got: ${actual}"
        die "The downloaded file may be corrupted."
    fi
}

# ── Download & verify ─────────────────────────────────────────────────────
download_and_verify() {
    step "Downloading claude-${VERSION}-${PLATFORM}..."
    mkdir -p "${DOWNLOAD_DIR}"

    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "${TMP_DIR}"' EXIT

    local bin_file="${TMP_DIR}/claude-${VERSION}-${PLATFORM}"
    local mirror
    for mirror in "${MIRROR_ORDER[@]}"; do
        if [[ "$mirror" == "$GCS_BUCKET" ]]; then
            _download_from_gcs "$bin_file" && break
        else
            _download_from_github "$bin_file" "$mirror" && break
        fi
        warn "  Failed, trying next source..."
    done

    [[ -f "$bin_file" ]] || die "Download failed from all sources. Check your network connection."

    BINARY_FILE="$bin_file"
    chmod +x "${BINARY_FILE}"
}

_download_from_gcs() {
    local bin_file="$1"
    local dl_url="${GCS_BUCKET}/${VERSION}/${PLATFORM}/claude"
    local manifest_url="${GCS_BUCKET}/${VERSION}/manifest.json"

    info "Source: GCS (official Anthropic)"
    info "URL: ${dl_url}"

    if ! curl -fL --connect-timeout 30 --max-time 300 \
         --progress-bar -o "${bin_file}" "${dl_url}" 2>/dev/null; then
        return 1
    fi

    _verify_from_manifest "$bin_file" "$manifest_url"
}

_download_from_github() {
    local bin_file="$1" mirror="$2"
    local filename="claude-${VERSION}-${PLATFORM}"
    local dl_url="${mirror}/${RELEASES_REPO}/releases/download/v${VERSION}/${filename}"
    local manifest_url="${mirror}/${RELEASES_REPO}/releases/download/v${VERSION}/manifest-${VERSION}.json"

    info "Source: $(_mirror_label "$mirror")"
    info "URL: ${dl_url}"

    if ! curl -fL --connect-timeout 30 --max-time 300 \
         --progress-bar -o "${bin_file}" "${dl_url}" 2>/dev/null; then
        return 1
    fi

    _verify_from_manifest "$bin_file" "$manifest_url"
}

# ── Run claude install (with fallback) ────────────────────────────────────
run_claude_install() {
    step "Setting up Claude Code..."
    info "Running: claude install${TARGET:+ $TARGET}"
    info "This may download additional components — please wait up to 90s..."

    local install_ok=false
    local install_cmd=("${BINARY_FILE}" install)
    [[ -n "$TARGET" ]] && install_cmd+=("$TARGET")

    if command -v timeout &>/dev/null; then
        if timeout 90 "${install_cmd[@]}"; then
            install_ok=true
        fi
    else
        if "${install_cmd[@]}"; then
            install_ok=true
        fi
    fi

    if $install_ok; then
        ok "claude install completed."
        return
    fi

    warn "claude install failed or timed out — switching to fallback installation."
    fallback_install
}

# ── Fallback: manual install when claude install fails ────────────────────
fallback_install() {
    detect_install_dir

    local dest="${INSTALL_DIR}/claude"
    if [[ -f "$dest" ]]; then
        rm -f "${dest}.old" 2>/dev/null || true
        mv "$dest" "${dest}.old" 2>/dev/null || true
    fi
    cp "${BINARY_FILE}" "$dest"
    rm -f "${dest}.old" 2>/dev/null || true

    mkdir -p "${DATA_DIR}"
    printf '%s\n' "${VERSION}" > "${VERSION_FILE}"
    ok "Installed (fallback): ${dest}"

    setup_path
}

# ── PATH setup (used only in fallback) ────────────────────────────────────
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

    $added || warn "Add manually: ${export_line}"
}

# ── Write ~/.claude.json ──────────────────────────────────────────────────
write_claude_json() {
    if [[ -f "$CLAUDE_JSON" ]]; then
        if command -v python3 &>/dev/null; then
            # shellcheck disable=SC2088 # tilde is in Python string, not bash
        python3 - <<'PYEOF' 2>/dev/null && ok "~/.claude.json: onboarding skip set." && return
import json, os
p = os.path.expanduser("~/.claude.json")
with open(p) as f:
    d = json.load(f)
d["hasCompletedOnboarding"] = True
with open(p, "w") as f:
    json.dump(d, f, indent=2)
PYEOF
        fi
        warn "Could not update ~/.claude.json — set hasCompletedOnboarding manually if needed."
    else
        printf '{"hasCompletedOnboarding": true}\n' > "$CLAUDE_JSON"
        ok "Created ~/.claude.json (onboarding skip)."
    fi
}

# ── Configure API / Provider ──────────────────────────────────────────────
configure_api_key() {
    step "Configuring API access..."

    local existing_key="${ANTHROPIC_API_KEY:-}"
    if [[ -n "$existing_key" ]] && [[ "$existing_key" != "PLACEHOLDER_USE_CC_SWITCH" ]]; then
        ok "ANTHROPIC_API_KEY already set."
        write_claude_json
        return
    fi

    local can_reach=false
    if curl -sf --connect-timeout 5 --max-time 5 \
        -o /dev/null "https://api.anthropic.com" 2>/dev/null; then
        can_reach=true
    elif curl -sf --connect-timeout 5 --max-time 5 \
        -o /dev/null -w "%{http_code}" "https://api.anthropic.com" 2>/dev/null | \
        grep -qE '^[0-9]+'; then
        can_reach=true
    fi

    local profile_files=()
    for rc in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile"; do
        [[ -f "$rc" ]] && profile_files+=("$rc")
    done

    if $CC_SWITCH_INSTALLED; then
        info "CC Switch installed → setting placeholder provider config..."
        for rc in "${profile_files[@]}"; do
            grep -qF "ANTHROPIC_BASE_URL" "$rc" 2>/dev/null || \
                printf '\nexport ANTHROPIC_BASE_URL="https://api.deepseek.com"\n' >> "$rc"
            grep -qF "ANTHROPIC_API_KEY" "$rc" 2>/dev/null || \
                printf 'export ANTHROPIC_API_KEY="PLACEHOLDER_USE_CC_SWITCH"\n' >> "$rc"
        done
        export ANTHROPIC_BASE_URL="https://api.deepseek.com"
        export ANTHROPIC_API_KEY="PLACEHOLDER_USE_CC_SWITCH"
        ok "Placeholder set. Open CC Switch to configure your Provider and API Key."

    elif $can_reach; then
        info "Anthropic API is reachable directly."
        if [ -t 0 ]; then
            printf "\n  ${YELLOW}Enter your Anthropic API Key (sk-ant-...), or press Enter to skip:${NC}\n"
            printf "  API Key: "
            read -r api_key </dev/tty
            if [[ -n "${api_key:-}" ]]; then
                local key_line="export ANTHROPIC_API_KEY=\"${api_key}\""
                for rc in "${profile_files[@]}"; do
                    grep -qF "ANTHROPIC_API_KEY" "$rc" 2>/dev/null || \
                        printf '\n%s\n' "$key_line" >> "$rc"
                done
                export ANTHROPIC_API_KEY="${api_key}"
                ok "API Key saved to shell profile."
            else
                warn "Skipped. Claude Code will prompt for API Key on first launch."
            fi
        fi

    else
        warn "Cannot reach api.anthropic.com directly."
        printf "\n"
        printf "  ${YELLOW}Recommended options:${NC}\n"
        printf "   1. Re-run installer and install CC Switch\n"
        printf "      → Use DeepSeek / Kimi / GLM / Aliyun as provider (no VPN needed)\n"
        printf "   2. Set up a proxy, then re-run installer\n"
        printf "   3. Set manually after install:\n"
        printf "      export ANTHROPIC_BASE_URL=\"https://api.your-provider.com\"\n"
        printf "      export ANTHROPIC_API_KEY=\"your-api-key\"\n\n"
    fi

    write_claude_json
}

# ── CC Switch: macOS ──────────────────────────────────────────────────────
install_cc_switch_macos() {
    local cc_ver="$1"
    local filename="CC-Switch-v${cc_ver}-macOS.tar.gz"
    local cc_url
    cc_url="$(make_download_url "/farion1231/cc-switch/releases/download/v${cc_ver}/${filename}")"
    local tmp_file="${TMP_DIR}/${filename}"

    info "Downloading ${filename}..."
    if ! curl -fL --connect-timeout 30 --max-time 300 --progress-bar \
         -o "$tmp_file" "$cc_url" 2>/dev/null; then
        warn "CC Switch download failed."
        info "Download manually: https://github.com/${CC_SWITCH_REPO}/releases"
        CC_SWITCH_INSTALLED=false
        return
    fi

    info "Extracting CC Switch.app to /Applications..."
    local extract_dir="${TMP_DIR}/cc-switch-extract"
    mkdir -p "$extract_dir"
    tar -xzf "$tmp_file" -C "$extract_dir" 2>/dev/null || true

    local app_path
    app_path="$(find "$extract_dir" -name "CC Switch.app" -maxdepth 4 2>/dev/null | head -1)"

    if [[ -n "$app_path" ]]; then
        rm -rf "/Applications/CC Switch.app" 2>/dev/null || true
        cp -R "$app_path" "/Applications/"
        ok "CC Switch installed: /Applications/CC Switch.app"
        CC_SWITCH_INSTALLED=true
    else
        warn "CC Switch.app not found in archive."
        CC_SWITCH_INSTALLED=false
    fi
}

# ── CC Switch: Linux ──────────────────────────────────────────────────────
install_cc_switch_linux() {
    local cc_ver="$1"
    local arch_suffix="x86_64"
    [[ "${PLATFORM}" == *arm64* ]] && arch_suffix="arm64"

    local filename="CC-Switch-v${cc_ver}-Linux-${arch_suffix}.AppImage"
    local cc_url
    cc_url="$(make_download_url "/farion1231/cc-switch/releases/download/v${cc_ver}/${filename}")"

    [[ -z "$INSTALL_DIR" ]] && detect_install_dir
    local dest="${INSTALL_DIR}/cc-switch"

    info "Downloading ${filename}..."
    if curl -fL --connect-timeout 30 --max-time 300 --progress-bar \
         -o "$dest" "$cc_url" 2>/dev/null; then
        chmod +x "$dest"
        ok "CC Switch installed: ${dest}"
        CC_SWITCH_INSTALLED=true
    else
        warn "CC Switch download failed."
        info "Download manually: https://github.com/${CC_SWITCH_REPO}/releases"
        CC_SWITCH_INSTALLED=false
    fi
}

# ── CC Switch prompt ──────────────────────────────────────────────────────
install_cc_switch_prompt() {
    [ -t 0 ] || return   # Skip in non-interactive (piped) mode

    printf "\n${BOLD}Install CC Switch (API Provider switcher)?${NC} [y/N] "
    read -r reply </dev/tty || { CC_SWITCH_INSTALLED=false; return; }
    if [[ ! "$reply" =~ ^[Yy] ]]; then
        CC_SWITCH_INSTALLED=false
        return
    fi

    step "Installing CC Switch..."

    local cc_ver=""
    local cc_api_response
    cc_api_response="$(curl -sf --connect-timeout 8 --max-time 15 \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${CC_SWITCH_REPO}/releases/latest" 2>/dev/null || true)"

    if [[ -n "$cc_api_response" ]]; then
        cc_ver="$(printf '%s' "$cc_api_response" | grep '"tag_name"' | head -1 | \
            sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/')"
    fi

    if [[ -z "$cc_ver" ]]; then
        warn "Could not fetch CC Switch version."
        info "Download manually: https://github.com/${CC_SWITCH_REPO}/releases"
        CC_SWITCH_INSTALLED=false
        return
    fi

    info "CC Switch version: v${cc_ver}"

    if [[ "${PLATFORM}" == darwin-* ]]; then
        install_cc_switch_macos "$cc_ver"
    elif [[ "${PLATFORM}" == linux-* ]]; then
        install_cc_switch_linux "$cc_ver"
    fi
}

# ── Done ──────────────────────────────────────────────────────────────────
print_done() {
    printf "\n"
    printf "${GREEN}${BOLD}  ✓ Claude Code v%s installed!${NC}\n\n" "${VERSION}"
    printf "  Quick start:\n"
    printf "    ${BOLD}claude${NC}            — start Claude Code\n"
    printf "    ${BOLD}claude --version${NC}  — verify installation\n"
    printf "\n"

    if $CC_SWITCH_INSTALLED; then
        if [[ "${PLATFORM}" == darwin-* ]]; then
            printf "  ${CYAN}CC Switch: open from /Applications/CC Switch.app${NC}\n"
        else
            printf "  ${CYAN}CC Switch: run 'cc-switch' or open the AppImage${NC}\n"
        fi
        printf "\n"
    fi

    printf "  To upgrade: re-run this installer\n"
    printf "  To uninstall: run uninstall.sh\n\n"

    if [[ -n "$INSTALL_DIR" ]] && ! printf '%s\n' "${PATH//:/$'\n'}" | grep -qx "${INSTALL_DIR}"; then
        printf "${YELLOW}  Restart your shell to use 'claude' command.${NC}\n\n"
    fi
}

# ── Entry point ───────────────────────────────────────────────────────────
main() {
    printf "\n${BOLD}${CYAN}━━━ Claude Code Installer ━━━${NC}  ProjectAILeap\n"
    printf "Source: github.com/ProjectAILeap/claude-code-releases\n\n"

    detect_platform
    get_latest_version
    check_installed_version
    check_git
    select_mirror
    download_and_verify
    run_claude_install
    install_cc_switch_prompt
    configure_api_key
    print_done
}

# Allow sourcing for testing without executing main
[[ "${BASH_SOURCE[0]:-$0}" != "${0}" ]] || main "$@"
