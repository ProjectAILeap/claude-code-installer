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
    read -r reply </dev/tty || reply="n"
    [[ "$reply" =~ ^[Yy] ]]
}

# ── Find claude binary ────────────────────────────────────────────────────────
find_binary() {
    BINARY_PATH=""

    # Check known install locations
    for candidate in \
        "${HOME}/.local/bin/claude" \
        "/usr/local/bin/claude" \
        "$(command -v claude 2>/dev/null || true)"; do
        if [[ -x "$candidate" ]]; then
            BINARY_PATH="$candidate"
            break
        fi
    done

    INSTALLED_VERSION=""
    if [[ -f "${DATA_DIR}/version" ]]; then
        INSTALLED_VERSION="$(cat "${DATA_DIR}/version" | tr -d '[:space:]')"
    fi
}

# ── Remove PATH entries ───────────────────────────────────────────────────────
remove_path_entries() {
    local binary_dir
    binary_dir="$(dirname "${BINARY_PATH}")"
    local modified=false

    for rc in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile"; do
        if [[ -f "$rc" ]] && grep -qF "$binary_dir" "$rc"; then
            # Remove the export line and its comment
            sed -i.bak '/# Added by claude-code-installer/d' "$rc"
            sed -i.bak "/export PATH=.*${binary_dir//\//\\/}.*/d" "$rc"
            rm -f "${rc}.bak"
            info "  Cleaned: $rc"
            modified=true
        fi
    done

    $modified && ok "PATH entries removed." || info "No PATH entries found."
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    printf "\n${BOLD}${CYAN}━━━ Claude Code Uninstaller ━━━${NC}  ProjectAILeap\n\n"

    find_binary

    if [[ -z "$BINARY_PATH" ]] && [[ -z "$INSTALLED_VERSION" ]]; then
        warn "Claude Code does not appear to be installed."
        info "Nothing to remove."
        exit 0
    fi

    # Show what was found
    step "Detected installation"
    [[ -n "$INSTALLED_VERSION" ]] && info "  Version:  v${INSTALLED_VERSION}"
    [[ -n "$BINARY_PATH"       ]] && info "  Binary:   ${BINARY_PATH}"
    info "  Data dir: ${DATA_DIR}"
    info "  Config:   ${CLAUDE_CONFIG_DIR}"

    printf "\n"

    # ── Selective removal ───────────────────────────────────────────────────
    REMOVE_BINARY=false
    REMOVE_DATA=false
    REMOVE_PATH=false
    REMOVE_CONFIG=false

    if [[ -n "$BINARY_PATH" ]] && ask "Remove Claude Code binary (${BINARY_PATH})?"; then
        REMOVE_BINARY=true
    fi

    if [[ -d "$DATA_DIR" ]] && ask "Remove version/data directory (~/.local/share/claude-code)?"; then
        REMOVE_DATA=true
    fi

    if [[ -n "$BINARY_PATH" ]] && ask "Remove PATH entries from shell profiles?"; then
        REMOVE_PATH=true
    fi

    if { [[ -d "$CLAUDE_CONFIG_DIR" ]] || [[ -f "$CLAUDE_CONFIG_FILE" ]]; } && \
       ask "Remove Claude configuration (~/.claude/ and ~/.claude.json)?"; then
        REMOVE_CONFIG=true
    fi

    # Confirm
    printf "\n${YELLOW}The following will be removed:${NC}\n"
    $REMOVE_BINARY && printf "  - Binary:      %s\n" "$BINARY_PATH"
    $REMOVE_DATA   && printf "  - Data dir:    %s\n" "$DATA_DIR"
    $REMOVE_PATH   && printf "  - PATH entries\n"
    $REMOVE_CONFIG && printf "  - Config:      %s  %s\n" "$CLAUDE_CONFIG_DIR" "$CLAUDE_CONFIG_FILE"

    if ! $REMOVE_BINARY && ! $REMOVE_DATA && ! $REMOVE_PATH && ! $REMOVE_CONFIG; then
        printf "\nNothing selected. Exiting.\n"
        exit 0
    fi

    printf "\n"
    ask "Proceed?" || { printf "\nCancelled.\n"; exit 0; }

    # ── Execute removals ────────────────────────────────────────────────────
    step "Removing..."

    if $REMOVE_BINARY; then
        rm -f "$BINARY_PATH"
        ok "Removed: $BINARY_PATH"
    fi

    if $REMOVE_DATA; then
        rm -rf "$DATA_DIR"
        ok "Removed: $DATA_DIR"
    fi

    if $REMOVE_PATH; then
        remove_path_entries
    fi

    if $REMOVE_CONFIG; then
        [[ -d "$CLAUDE_CONFIG_DIR"  ]] && rm -rf "$CLAUDE_CONFIG_DIR"  && ok "Removed: $CLAUDE_CONFIG_DIR"
        [[ -f "$CLAUDE_CONFIG_FILE" ]] && rm -f  "$CLAUDE_CONFIG_FILE" && ok "Removed: $CLAUDE_CONFIG_FILE"
    fi

    printf "\n${GREEN}${BOLD}  Uninstall complete.${NC}\n\n"
}

main "$@"
