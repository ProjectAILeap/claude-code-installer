#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
#  Claude Code Uninstaller — ProjectAILeap
#  https://github.com/ProjectAILeap/claude-code-installer
# ════════════════════════════════════════════════════════════════════════════
set -euo pipefail

DATA_DIR="${HOME}/.local/share/claude-code"
CLAUDE_CONFIG_DIR="${HOME}/.claude"
CLAUDE_CONFIG_FILE="${HOME}/.claude.json"

# ── Colors ────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

info()  { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[ OK ]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
step()  { printf "\n${BOLD}${CYAN}▶ %s${NC}\n" "$*"; }

ask() {
    printf "${BOLD}%s${NC} [y/N] " "$1"
    local reply="n"
    read -r reply </dev/tty || reply="n"
    [[ "$reply" =~ ^[Yy] ]]
}

# ── Detect platform ───────────────────────────────────────────────────────────
detect_os() {
    OS="$(uname -s)"
}

# ── Find claude binary ────────────────────────────────────────────────────────
find_installation() {
    BINARY_PATH=""
    for candidate in \
        "${HOME}/.local/bin/claude" \
        "/usr/local/bin/claude" \
        "$(command -v claude 2>/dev/null || true)"; do
        if [[ -n "$candidate" ]] && [[ -x "$candidate" ]]; then
            BINARY_PATH="$candidate"
            break
        fi
    done

    INSTALLED_VERSION=""
    if [[ -f "${DATA_DIR}/version" ]]; then
        INSTALLED_VERSION="$(cat "${DATA_DIR}/version" | tr -d '[:space:]')"
    fi

    INSTALL_DIR=""
    if [[ -n "$BINARY_PATH" ]]; then
        INSTALL_DIR="$(dirname "${BINARY_PATH}")"
    fi
}

# ── Detect CC Switch ──────────────────────────────────────────────────────────
find_cc_switch() {
    CC_SWITCH_PATH=""
    CC_SWITCH_LABEL=""

    if [[ "$OS" == "Darwin" ]]; then
        if [[ -d "/Applications/CC Switch.app" ]]; then
            CC_SWITCH_PATH="/Applications/CC Switch.app"
            CC_SWITCH_LABEL="/Applications/CC Switch.app"
        fi
    else
        # Linux: look for AppImage in common locations
        for candidate in \
            "${INSTALL_DIR}/cc-switch" \
            "${HOME}/.local/bin/cc-switch" \
            "$(command -v cc-switch 2>/dev/null || true)"; do
            if [[ -n "$candidate" ]] && [[ -x "$candidate" ]]; then
                CC_SWITCH_PATH="$candidate"
                CC_SWITCH_LABEL="$candidate"
                break
            fi
        done
    fi
}

# ── Detect ANTHROPIC env vars in shell profiles ───────────────────────────────
find_anthropic_env() {
    PROFILES_WITH_ANTHROPIC=()
    for rc in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile"; do
        if [[ -f "$rc" ]] && grep -qE "ANTHROPIC_(BASE_URL|API_KEY)" "$rc" 2>/dev/null; then
            PROFILES_WITH_ANTHROPIC+=("$rc")
        fi
    done
}

# ── Remove PATH entries from shell profiles ───────────────────────────────────
remove_path_entries() {
    local binary_dir="$1"

    for rc in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile"; do
        if [[ -f "$rc" ]] && grep -qF "$binary_dir" "$rc"; then
            sed -i.bak '/# Added by claude-code-installer/d' "$rc"
            sed -i.bak "/export PATH=.*${binary_dir//\//\\/}.*/d" "$rc"
            rm -f "${rc}.bak"
            info "  Cleaned PATH in: $rc"
        fi
    done
}

# ── Remove ANTHROPIC env vars from shell profiles ─────────────────────────────
remove_anthropic_env() {
    for rc in "${PROFILES_WITH_ANTHROPIC[@]:-}"; do
        [[ -z "$rc" ]] && continue
        sed -i.bak '/ANTHROPIC_BASE_URL/d' "$rc"
        sed -i.bak '/ANTHROPIC_API_KEY/d' "$rc"
        rm -f "${rc}.bak"
        info "  Cleaned ANTHROPIC_* from: $rc"
    done
    ok "ANTHROPIC_* environment variables removed."
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    printf "\n${BOLD}${CYAN}━━━ Claude Code Uninstaller ━━━${NC}  ProjectAILeap\n\n"

    detect_os
    find_installation
    find_cc_switch
    find_anthropic_env

    if [[ -z "$BINARY_PATH" ]] && [[ -z "$INSTALLED_VERSION" ]]; then
        warn "Claude Code does not appear to be installed."
        info "Nothing to remove."
        exit 0
    fi

    # ── Show detected state ──────────────────────────────────────────────────
    step "Detected installation"
    [[ -n "$INSTALLED_VERSION" ]] && info "  Version:  v${INSTALLED_VERSION}"
    [[ -n "$BINARY_PATH"       ]] && info "  Binary:   ${BINARY_PATH}"
    info "  Data dir: ${DATA_DIR}"
    [[ -n "$CC_SWITCH_LABEL"   ]] && info "  CC Switch: ${CC_SWITCH_LABEL}"
    [[ ${#PROFILES_WITH_ANTHROPIC[@]} -gt 0 ]] && \
        info "  ANTHROPIC_* env: ${PROFILES_WITH_ANTHROPIC[*]}"
    printf "\n"

    # ── Collect choices ──────────────────────────────────────────────────────
    REMOVE_BINARY=false
    REMOVE_DATA=false
    REMOVE_PATH=false
    REMOVE_CONFIG=false
    REMOVE_CC_SWITCH=false
    REMOVE_ANTHROPIC_ENV=false

    [[ -n "$BINARY_PATH" ]] && \
        ask "Remove Claude Code binary (${BINARY_PATH})?" && REMOVE_BINARY=true

    [[ -d "$DATA_DIR" ]] && \
        ask "Remove data directory (~/.local/share/claude-code)?" && REMOVE_DATA=true

    [[ -n "$BINARY_PATH" ]] && \
        ask "Remove PATH entries from shell profiles?" && REMOVE_PATH=true

    { [[ -d "$CLAUDE_CONFIG_DIR" ]] || [[ -f "$CLAUDE_CONFIG_FILE" ]]; } && \
        ask "Remove Claude configuration (~/.claude/ and ~/.claude.json)?" && REMOVE_CONFIG=true

    [[ -n "$CC_SWITCH_PATH" ]] && \
        ask "Remove CC Switch (${CC_SWITCH_LABEL})?" && REMOVE_CC_SWITCH=true

    [[ ${#PROFILES_WITH_ANTHROPIC[@]} -gt 0 ]] && \
        ask "Remove ANTHROPIC_* variables from shell profiles?" && REMOVE_ANTHROPIC_ENV=true

    # ── Confirm ──────────────────────────────────────────────────────────────
    if ! $REMOVE_BINARY && ! $REMOVE_DATA && ! $REMOVE_PATH && \
       ! $REMOVE_CONFIG && ! $REMOVE_CC_SWITCH && ! $REMOVE_ANTHROPIC_ENV; then
        printf "\nNothing selected. Exiting.\n"
        exit 0
    fi

    printf "\n${YELLOW}The following will be removed:${NC}\n"
    $REMOVE_BINARY       && printf "  - Binary:         %s\n" "$BINARY_PATH"
    $REMOVE_DATA         && printf "  - Data dir:       %s\n" "$DATA_DIR"
    $REMOVE_PATH         && printf "  - PATH entries\n"
    $REMOVE_CONFIG       && printf "  - Config:         %s  %s\n" \
                                    "$CLAUDE_CONFIG_DIR" "$CLAUDE_CONFIG_FILE"
    $REMOVE_CC_SWITCH    && printf "  - CC Switch:      %s\n" "$CC_SWITCH_LABEL"
    $REMOVE_ANTHROPIC_ENV && printf "  - ANTHROPIC_* env from shell profiles\n"

    printf "\n"
    ask "Proceed?" || { printf "\nCancelled.\n"; exit 0; }

    # ── Execute ──────────────────────────────────────────────────────────────
    step "Removing..."

    if $REMOVE_BINARY; then
        rm -f "$BINARY_PATH"
        ok "Removed: $BINARY_PATH"
    fi

    if $REMOVE_DATA; then
        rm -rf "$DATA_DIR"
        ok "Removed: $DATA_DIR"
    fi

    if $REMOVE_PATH && [[ -n "$INSTALL_DIR" ]]; then
        remove_path_entries "$INSTALL_DIR"
        ok "PATH entries removed."
    fi

    if $REMOVE_CONFIG; then
        [[ -d "$CLAUDE_CONFIG_DIR"  ]] && rm -rf "$CLAUDE_CONFIG_DIR"  && ok "Removed: $CLAUDE_CONFIG_DIR"
        [[ -f "$CLAUDE_CONFIG_FILE" ]] && rm -f  "$CLAUDE_CONFIG_FILE" && ok "Removed: $CLAUDE_CONFIG_FILE"
    fi

    if $REMOVE_CC_SWITCH && [[ -n "$CC_SWITCH_PATH" ]]; then
        if [[ "$OS" == "Darwin" ]]; then
            rm -rf "$CC_SWITCH_PATH"
        else
            rm -f "$CC_SWITCH_PATH"
        fi
        ok "Removed: ${CC_SWITCH_LABEL}"
    fi

    if $REMOVE_ANTHROPIC_ENV; then
        remove_anthropic_env
    fi

    printf "\n${GREEN}${BOLD}  Uninstall complete.${NC}\n\n"
}

main "$@"
