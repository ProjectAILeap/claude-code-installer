# Desktop App Install Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Claude Desktop App install/uninstall support to `claude-code-installer`, and fix the broken CLI version detection caused by `/releases/latest` returning the Desktop release.

**Architecture:** Add new functions to existing scripts (`install.sh`, `install.ps1`, `uninstall.sh`, `uninstall.ps1`). Replace the current `get_latest_version` (GitHub API `/releases/latest`) with a README-based parser that fetches both CLI and Desktop versions in one request. Add product selection menu (macOS/Windows only), Desktop download/verify/install functions, and corresponding uninstall logic.

**Tech Stack:** Bash (install.sh/uninstall.sh), PowerShell (install.ps1/uninstall.ps1), existing mirror/checksum infrastructure.

**Spec:** `docs/superpowers/specs/2026-04-30-desktop-app-install-design.md`

---

### Task 1: Replace `get_latest_version` with README-based version parser (install.sh)

This task fixes the existing bug where `/releases/latest` returns the Desktop release instead of the CLI release, AND adds Desktop version detection.

**Files:**
- Modify: `install.sh:305-330` (replace `get_latest_version` function)

- [ ] **Step 1: Write the new `get_latest_version` function**

Replace the existing `get_latest_version` function (lines 305-330) with:

```bash
get_latest_version() {
    step "Fetching latest version..."
    VERSION=""
    DESKTOP_VERSION=""

    local readme=""
    local readme_urls=(
        "${GITHUB_MIRROR:-https://github.com}/${RELEASES_REPO}/raw/main/README.md"
        "https://raw.githubusercontent.com/${RELEASES_REPO}/main/README.md"
    )

    for url in "${readme_urls[@]}"; do
        readme="$(curl -sf --connect-timeout 8 --max-time 15 "$url" 2>/dev/null || true)"
        [[ -n "$readme" ]] && break
    done

    if [[ -n "$readme" ]]; then
        VERSION="$(printf '%s' "$readme" | grep -oE 'releases/tag/v[0-9]+\.[0-9]+\.[0-9]+' | grep -v desktop | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
        DESKTOP_VERSION="$(printf '%s' "$readme" | grep -oE 'releases/tag/desktop-v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
    fi

    if [[ -z "${VERSION:-}" ]]; then
        info "README unavailable, trying API fallback..."
        local api_response
        api_response="$(curl -sf --connect-timeout 8 --max-time 15 \
            -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/repos/${RELEASES_REPO}/releases?per_page=20" 2>/dev/null || true)"

        if [[ -n "$api_response" ]]; then
            VERSION="$(printf '%s' "$api_response" | grep '"tag_name"' | grep -v desktop | head -1 | \
                sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/')"
            [[ -z "${DESKTOP_VERSION:-}" ]] && \
                DESKTOP_VERSION="$(printf '%s' "$api_response" | grep '"tag_name".*desktop-v' | head -1 | \
                    sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"desktop-v\([^"]*\)".*/\1/')"
        fi
    fi

    if [[ -z "${VERSION:-}" ]]; then
        info "API unavailable, trying redirect fallback..."
        local location
        location="$(curl -sI --connect-timeout 8 --max-time 12 \
            "https://github.com/${RELEASES_REPO}/releases" 2>/dev/null | \
            grep -i '^location:' | tr -d '\r' | awk '{print $2}')"
        VERSION="$(printf '%s' "$location" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    fi

    [[ -n "${VERSION:-}" ]] || die "Cannot determine latest CLI version. Check network."
    info "CLI: v${VERSION}"
    [[ -n "${DESKTOP_VERSION:-}" ]] && info "Desktop: v${DESKTOP_VERSION}"
}
```

- [ ] **Step 2: Add `DESKTOP_VERSION=""` to global variables**

After line 39 (`INSTALL_METHOD=""`), add:

```bash
DESKTOP_VERSION=""
```

- [ ] **Step 3: Run test layer 1 (shellcheck)**

Run: `bash tests/test.sh 1`
Expected: PASS

- [ ] **Step 4: Run test layer 2 (get_latest_version test)**

Run: `bash tests/test.sh 2`
Expected: PASS — `get_latest_version` still sets `VERSION` to a valid semver string

- [ ] **Step 5: Commit**

```bash
git add install.sh
git commit -m "Replace /releases/latest with README-based version parser

Fixes CLI version detection broken by Desktop releases claiming /releases/latest.
Both CLI and Desktop versions now parsed from a single README fetch."
```

---

### Task 2: Add product selection menu and Desktop control flow (install.sh)

**Files:**
- Modify: `install.sh:1076-1134` (main function)

- [ ] **Step 1: Add `INSTALL_CLI`, `INSTALL_DESKTOP`, and `DESKTOP_FILE` variables**

After the `DESKTOP_VERSION=""` line added in Task 1, add:

```bash
INSTALL_CLI=true
INSTALL_DESKTOP=false
DESKTOP_FILE=""
```

- [ ] **Step 2: Add `select_product` function**

Insert before the `main()` function (before line 1076):

```bash
select_product() {
    if [[ "${PLATFORM}" != darwin-* ]]; then
        INSTALL_CLI=true
        INSTALL_DESKTOP=false
        return
    fi

    if [[ -z "${DESKTOP_VERSION:-}" ]]; then
        warn "Could not detect Desktop App version, only CLI available."
        INSTALL_CLI=true
        INSTALL_DESKTOP=false
        return
    fi

    printf "\n${BOLD}What would you like to install?${NC}\n"
    printf "  [1] Claude Code (CLI)\n"
    printf "  [2] Claude Desktop App\n"
    printf "  [3] Both\n"
    printf "\n"
    local product_choice="1"
    [ -t 0 ] && { printf "Enter choice [1]: "; read -r product_choice </dev/tty || true; }
    [[ -z "$product_choice" ]] && product_choice="1"

    case "$product_choice" in
        2)
            INSTALL_CLI=false
            INSTALL_DESKTOP=true
            ;;
        3)
            INSTALL_CLI=true
            INSTALL_DESKTOP=true
            ;;
        *)
            INSTALL_CLI=true
            INSTALL_DESKTOP=false
            ;;
    esac
}
```

- [ ] **Step 3: Restructure `main()` to use product selection**

Replace the main function (lines 1076-1134) with:

```bash
main() {
    printf "\n${BOLD}${CYAN}━━━ Claude Code Installer ━━━${NC}  ProjectAILeap\n"
    printf "Source: github.com/ProjectAILeap/claude-code-releases\n\n"

    detect_platform
    get_latest_version
    select_product

    if $INSTALL_CLI; then
        check_installed_version

        if [[ "$INSTALLED_VERSION" == "$VERSION" ]]; then
            ok "Claude Code v${VERSION} is already up to date."
            if [[ -n "$CLAUDE_BIN" ]] && ! command -v claude &>/dev/null; then
                INSTALL_DIR="$(dirname "$CLAUDE_BIN")"
                setup_path
            fi
        fi
    fi

    local cli_needs_install=false
    if $INSTALL_CLI && [[ "${INSTALLED_VERSION:-}" != "$VERSION" ]]; then
        cli_needs_install=true
        if [[ -n "$INSTALLED_VERSION" ]]; then
            info "Upgrading: v${INSTALLED_VERSION} → v${VERSION}"
        else
            info "Installing Claude Code v${VERSION}"
        fi
    fi

    local desktop_needs_install=false
    if $INSTALL_DESKTOP; then
        if is_desktop_installed; then
            printf "\n"
            printf "${BOLD}Desktop App is already installed. Overwrite?${NC} [y/N] "
            local reply="n"
            [ -t 0 ] && read -r reply </dev/tty || reply="n"
            [[ "$reply" =~ ^[Yy] ]] && desktop_needs_install=true
        else
            desktop_needs_install=true
        fi
    fi

    if ! $cli_needs_install && ! $desktop_needs_install; then
        if $INSTALL_CLI; then
            if is_cc_switch_installed; then
                ok "CC Switch is already installed."
                CC_SWITCH_INSTALLED=true
            else
                TMP_DIR="$(mktemp -d)"
                trap 'rm -rf "${TMP_DIR}"' EXIT
                install_cc_switch_prompt
            fi
            configure_api_key
        fi
        print_done
        exit 0
    fi

    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "${TMP_DIR}"' EXIT

    if $cli_needs_install; then
        printf "\n${BOLD}Select install method:${NC}\n"
        printf "  [1] Direct binary (Recommended) — downloads official binary, verifies SHA-256\n"
        printf "  [2] npm (via npmmirror)          — installs via npm registry\n"
        printf "\n"
        local method_choice="1"
        [ -t 0 ] && { printf "Enter choice [1]: "; read -r method_choice </dev/tty || true; }
        [[ -z "$method_choice" ]] && method_choice="1"

        if [[ "$method_choice" == "2" ]]; then
            install_via_npm
        else
            check_git
            select_mirror
            download_and_verify
            run_claude_install
        fi
    fi

    if $desktop_needs_install; then
        if [[ -z "${GITHUB_MIRROR}" ]] || [[ ${#MIRROR_ORDER[@]} -eq 0 ]]; then
            select_mirror
        fi
        download_desktop
        install_desktop
    fi

    if $INSTALL_CLI; then
        install_cc_switch_prompt
        configure_api_key
    fi

    print_done
}
```

- [ ] **Step 4: Run shellcheck**

Run: `bash tests/test.sh 1`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add install.sh
git commit -m "Add product selection menu and Desktop control flow

macOS: show CLI/Desktop/Both menu before install method selection.
Linux: menu skipped, CLI only (Desktop has no Linux version).
Conditional execution of Git check, CC Switch, API Key based on product choice."
```

---

### Task 3: Add Desktop download, verify, and install functions (install.sh)

**Files:**
- Modify: `install.sh` (add new functions before `main()`)

- [ ] **Step 1: Add `is_desktop_installed` function**

Insert after the `is_cc_switch_installed` function (after line 797):

```bash
is_desktop_installed() {
    [[ -d "/Applications/Claude.app" ]]
}
```

- [ ] **Step 2: Add `get_desktop_filename` function**

```bash
get_desktop_filename() {
    printf "Claude-%s-darwin-universal.dmg" "${DESKTOP_VERSION}"
}
```

- [ ] **Step 3: Add `download_desktop` function**

```bash
download_desktop() {
    step "Downloading Claude Desktop App v${DESKTOP_VERSION}..."
    mkdir -p "${DOWNLOAD_DIR}"

    local filename
    filename="$(get_desktop_filename)"
    local cache_file="${DOWNLOAD_DIR}/${filename}"
    local sha_file="${DOWNLOAD_DIR}/desktop-sha256sums-${DESKTOP_VERSION}.txt"

    # Download sha256sums.txt for verification
    local sha_downloaded=false
    if [[ ! -f "$sha_file" ]]; then
        for mirror in "${MIRROR_ORDER[@]}"; do
            local sha_url="${mirror}/${RELEASES_REPO}/releases/download/desktop-v${DESKTOP_VERSION}/sha256sums.txt"
            if curl -fsSL --connect-timeout 15 --max-time 30 -o "$sha_file" "$sha_url" 2>/dev/null; then
                sha_downloaded=true
                break
            fi
        done
    else
        sha_downloaded=true
    fi

    # Check cache
    if [[ -f "$cache_file" ]]; then
        if $sha_downloaded; then
            local expected actual
            expected="$(grep "$filename" "$sha_file" 2>/dev/null | awk '{print $1}')"
            if [[ -n "$expected" ]]; then
                if command -v sha256sum &>/dev/null; then
                    actual="$(sha256sum "$cache_file" | awk '{print $1}')"
                elif command -v shasum &>/dev/null; then
                    actual="$(shasum -a 256 "$cache_file" | awk '{print $1}')"
                fi
                if [[ "$actual" == "$expected" ]]; then
                    ok "Using cached ${filename} (checksum OK)."
                    DESKTOP_FILE="$cache_file"
                    return
                else
                    warn "Cached file checksum mismatch, re-downloading..."
                    rm -f "$cache_file"
                fi
            else
                ok "Using cached ${filename} (no checksum entry found)."
                DESKTOP_FILE="$cache_file"
                return
            fi
        else
            ok "Using cached ${filename} (no checksum available)."
            DESKTOP_FILE="$cache_file"
            return
        fi
    fi

    # Download DMG
    local mirror
    for mirror in "${MIRROR_ORDER[@]}"; do
        local dl_url="${mirror}/${RELEASES_REPO}/releases/download/desktop-v${DESKTOP_VERSION}/${filename}"
        info "Source: $(_mirror_label "$mirror")"
        if curl -fL --connect-timeout 30 --max-time 600 \
             --progress-bar -o "${cache_file}" "${dl_url}" 2>/dev/null; then
            # Verify checksum
            if $sha_downloaded; then
                local expected actual
                expected="$(grep "$filename" "$sha_file" 2>/dev/null | awk '{print $1}')"
                if [[ -n "$expected" ]]; then
                    if command -v sha256sum &>/dev/null; then
                        actual="$(sha256sum "$cache_file" | awk '{print $1}')"
                    elif command -v shasum &>/dev/null; then
                        actual="$(shasum -a 256 "$cache_file" | awk '{print $1}')"
                    fi
                    if [[ "$actual" == "$expected" ]]; then
                        ok "SHA-256 verified."
                    else
                        err "Checksum mismatch! Expected: ${expected} Got: ${actual}"
                        rm -f "$cache_file"
                        continue
                    fi
                fi
            fi
            DESKTOP_FILE="$cache_file"
            return
        fi
        warn "  Failed, trying next mirror..."
    done

    [[ -f "$cache_file" ]] || die "Desktop App download failed from all mirrors."
    DESKTOP_FILE="$cache_file"
}
```

- [ ] **Step 4: Add `install_desktop` function**

```bash
install_desktop() {
    step "Installing Claude Desktop App..."

    local mount_output mount_point app_path app_name

    mount_output="$(hdiutil attach "${DESKTOP_FILE}" -nobrowse -quiet 2>&1)" || {
        warn "Failed to mount DMG."
        info "DMG saved at: ${DESKTOP_FILE}"
        info "Double-click the DMG file to install manually."
        return
    }

    mount_point="$(printf '%s' "$mount_output" | grep -oE '/Volumes/[^\t]*' | head -1 | sed 's/[[:space:]]*$//')"
    if [[ -z "$mount_point" ]]; then
        warn "Could not determine mount point."
        info "DMG saved at: ${DESKTOP_FILE}"
        return
    fi

    app_path="$(find "$mount_point" -maxdepth 1 -name '*.app' -print -quit 2>/dev/null)"
    if [[ -z "$app_path" ]]; then
        hdiutil detach "$mount_point" -quiet 2>/dev/null || true
        warn "No .app found in DMG."
        info "DMG saved at: ${DESKTOP_FILE}"
        return
    fi

    app_name="$(basename "$app_path")"
    info "Found: ${app_name}"

    rm -rf "/Applications/${app_name}" 2>/dev/null || true
    cp -R "$app_path" /Applications/
    hdiutil detach "$mount_point" -quiet 2>/dev/null || true
    xattr -cr "/Applications/${app_name}" 2>/dev/null || true

    ok "Claude Desktop App installed: /Applications/${app_name}"
}
```

- [ ] **Step 5: Run shellcheck**

Run: `bash tests/test.sh 1`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add install.sh
git commit -m "Add Desktop App download, verify, and install functions

download_desktop: downloads DMG from GitHub mirrors with SHA-256 verification and caching.
install_desktop: mounts DMG, copies .app to /Applications, removes quarantine attribute.
Dynamically detects mount point and .app name (no hardcoded paths)."
```

---

### Task 4: Update `print_done` to show Desktop App info (install.sh)

**Files:**
- Modify: `install.sh` (`print_done` function)

- [ ] **Step 1: Add Desktop App info to `print_done`**

After the CC Switch display block in `print_done` (after the `fi` that closes the CC Switch section), add:

```bash
    if $INSTALL_DESKTOP && [[ -d "/Applications/Claude.app" ]]; then
        printf "  ${CYAN}Claude Desktop App: /Applications/Claude.app${NC}\n"
        printf "\n"
    fi
```

- [ ] **Step 2: Commit**

```bash
git add install.sh
git commit -m "Show Desktop App path in install completion summary"
```

---

### Task 5: Add Desktop App uninstall support (uninstall.sh)

**Files:**
- Modify: `uninstall.sh`

- [ ] **Step 1: Add Desktop App detection function**

After `find_cc_switch` function (after line 85), add:

```bash
find_desktop_app() {
    DESKTOP_APP_PATH=""
    if [[ "$OS" == "Darwin" ]] && [[ -d "/Applications/Claude.app" ]]; then
        DESKTOP_APP_PATH="/Applications/Claude.app"
    fi
}
```

- [ ] **Step 2: Add detection call in main**

After `find_anthropic_env` (line 159), add:

```bash
    find_desktop_app
```

- [ ] **Step 3: Add Desktop App to detected state display**

After the CC Switch info line (after line 173), add:

```bash
    [[ -n "$DESKTOP_APP_PATH"  ]] && info "  Desktop: ${DESKTOP_APP_PATH}"
```

- [ ] **Step 4: Update "nothing installed" check**

Change line 161 from:

```bash
    if [[ -z "$BINARY_PATH" ]] && [[ -z "$INSTALLED_VERSION" ]] && ! $NPM_INSTALL_FOUND; then
```

to:

```bash
    if [[ -z "$BINARY_PATH" ]] && [[ -z "$INSTALLED_VERSION" ]] && ! $NPM_INSTALL_FOUND && [[ -z "$DESKTOP_APP_PATH" ]]; then
```

- [ ] **Step 5: Add Desktop App uninstall choice and variable**

After the `REMOVE_ANTHROPIC_ENV` choice block, add:

```bash
    REMOVE_DESKTOP=false

    [[ -n "$DESKTOP_APP_PATH" ]] && \
        ask "Remove Claude Desktop App (${DESKTOP_APP_PATH})?" && REMOVE_DESKTOP=true
```

- [ ] **Step 6: Update "nothing selected" check**

Change the check to include `$REMOVE_DESKTOP`:

```bash
    if ! $REMOVE_BINARY && ! $REMOVE_NPM && ! $REMOVE_DATA && ! $REMOVE_PATH && \
       ! $REMOVE_CONFIG && ! $REMOVE_CC_SWITCH && ! $REMOVE_ANTHROPIC_ENV && ! $REMOVE_DESKTOP; then
```

- [ ] **Step 7: Add Desktop to removal summary**

After the CC Switch summary line, add:

```bash
    $REMOVE_DESKTOP      && printf "  - Desktop:        %s\n" "$DESKTOP_APP_PATH"
```

- [ ] **Step 8: Add Desktop App removal execution**

After the CC Switch removal block, add:

```bash
    if $REMOVE_DESKTOP && [[ -n "$DESKTOP_APP_PATH" ]]; then
        rm -rf "$DESKTOP_APP_PATH"
        ok "Removed: ${DESKTOP_APP_PATH}"
        local dmg
        for dmg in "${HOME}/.claude/downloads"/Claude-*-darwin-universal.dmg; do
            [[ -f "$dmg" ]] && rm -f "$dmg" && info "  Cleaned cache: $(basename "$dmg")"
        done
        info "Desktop App user data (if any): ~/Library/Application Support/Claude/"
    fi
```

- [ ] **Step 9: Run shellcheck on uninstall.sh**

Run: `shellcheck uninstall.sh`
Expected: No errors

- [ ] **Step 10: Commit**

```bash
git add uninstall.sh
git commit -m "Add Desktop App detection and uninstall support

Detects /Applications/Claude.app, prompts for removal, cleans up cached DMG files.
Prints user data path for manual cleanup reference."
```

---

### Task 6: Add Desktop App support to install.ps1

**Files:**
- Modify: `install.ps1`

- [ ] **Step 1: Add global variables**

After `$global:InstalledClaudeExe = ""` (line 158), add:

```powershell
$global:InstallCli     = $true
$global:InstallDesktop = $false
$global:DesktopVersion = ""
$global:DesktopFile    = ""
```

- [ ] **Step 2: Replace `Get-LatestVersion` with README-based parser**

Replace the `Get-LatestVersion` function (lines 255-291) with:

```powershell
function Get-LatestVersion {
    Write-Step "Fetching latest version..."
    $ver = ""
    $global:DesktopVersion = ""

    $readmeUrls = @(
        "https://raw.githubusercontent.com/$RELEASES_REPO/main/README.md",
        "https://github.com/$RELEASES_REPO/raw/main/README.md"
    )

    $readme = ""
    foreach ($url in $readmeUrls) {
        try {
            $resp = Invoke-WebRequest -Uri $url -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
            $readme = $resp.Content
            break
        } catch {}
    }

    if ($readme) {
        if ($readme -match 'releases/tag/v(\d+\.\d+\.\d+)') {
            $ver = $Matches[1]
        }
        if ($readme -match 'releases/tag/desktop-v(\d+\.\d+\.\d+)') {
            $global:DesktopVersion = $Matches[1]
        }
    }

    if (-not $ver) {
        Write-Info "README unavailable, trying API fallback..."
        try {
            $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$RELEASES_REPO/releases?per_page=20" `
                -TimeoutSec 15 -Headers @{ Accept = "application/vnd.github.v3+json" } -ErrorAction Stop
            foreach ($r in $releases) {
                if (-not $ver -and $r.tag_name -match '^v(\d+\.\d+\.\d+)$') {
                    $ver = $Matches[1]
                }
                if (-not $global:DesktopVersion -and $r.tag_name -match '^desktop-v(\d+\.\d+\.\d+)$') {
                    $global:DesktopVersion = $Matches[1]
                }
                if ($ver -and $global:DesktopVersion) { break }
            }
        } catch {
            Write-Info "API unavailable, trying redirect fallback..."
        }
    }

    if (-not $ver) {
        try {
            $resp = Invoke-WebRequest -Uri "https://github.com/$RELEASES_REPO/releases" -Method Head `
                -TimeoutSec 10 -UseBasicParsing -MaximumRedirection 0 -ErrorAction SilentlyContinue
            $location = $resp.Headers["Location"]
            if ($location -and "$location" -match '(\d+\.\d+\.\d+)') { $ver = $Matches[1] }
        } catch {
            if ($_.Exception.Response) {
                $loc = $_.Exception.Response.Headers.Location
                if ($loc -and "$loc" -match '(\d+\.\d+\.\d+)') { $ver = $Matches[1] }
            }
        }
    }

    if (-not $ver) {
        Exit-WithError "Cannot determine latest version. Check network connectivity."
    }
    Write-Info "CLI: v$ver"
    if ($global:DesktopVersion) { Write-Info "Desktop: v$($global:DesktopVersion)" }
    return $ver
}
```

- [ ] **Step 3: Add `Select-Product` function**

Insert before the `Main` function:

```powershell
function Select-Product {
    if (-not $global:DesktopVersion) {
        Write-Warn "Could not detect Desktop App version, only CLI available."
        $global:InstallCli     = $true
        $global:InstallDesktop = $false
        return
    }

    Write-Host ""
    Write-Host "What would you like to install?" -ForegroundColor Cyan
    Write-Host "  [1] Claude Code (CLI)"
    Write-Host "  [2] Claude Desktop App"
    Write-Host "  [3] Both"
    Write-Host ""
    $choice = Read-Host "Enter choice [1]"
    if (-not $choice) { $choice = "1" }

    switch ($choice) {
        "2" {
            $global:InstallCli     = $false
            $global:InstallDesktop = $true
        }
        "3" {
            $global:InstallCli     = $true
            $global:InstallDesktop = $true
        }
        default {
            $global:InstallCli     = $true
            $global:InstallDesktop = $false
        }
    }
}
```

- [ ] **Step 4: Add `Test-DesktopInstalled` function**

```powershell
function Test-DesktopInstalled {
    return (Test-Path "$env:LOCALAPPDATA\Claude\Claude.exe")
}
```

- [ ] **Step 5: Add `Install-DesktopApp` function**

```powershell
function Install-DesktopApp {
    param([string]$Version)

    Write-Step "Installing Claude Desktop App v$Version..."
    $desktopPlatform = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "win32-arm64" } else { "win32-x64" }
    $fileName = "ClaudeSetup-$Version-$desktopPlatform.exe"
    $filePath = "$DOWNLOAD_DIR\$fileName"
    $shaFile  = "$DOWNLOAD_DIR\desktop-sha256sums-$Version.txt"

    New-Item -ItemType Directory -Force -Path $DOWNLOAD_DIR | Out-Null

    # Download sha256sums.txt
    $shaOk = $false
    if (Test-Path $shaFile) {
        $shaOk = $true
    } else {
        $shaOk = Invoke-DownloadMirror `
            -Path "/$RELEASES_REPO/releases/download/desktop-v$Version/sha256sums.txt" `
            -OutFile $shaFile -Label "Desktop sha256sums.txt"
    }

    # Check cache
    $needDownload = $true
    if (Test-Path $filePath) {
        if ($shaOk) {
            $shaContent = Get-Content $shaFile -Raw -ErrorAction SilentlyContinue
            $escapedName = [regex]::Escape($fileName)
            if ($shaContent -match "([a-f0-9]{64})\s+$escapedName") {
                $expected = $Matches[1]
                $actual = (Get-FileHash -Path $filePath -Algorithm SHA256).Hash.ToLower()
                if ($actual -eq $expected) {
                    Write-Ok "Using cached $fileName (checksum OK)."
                    $needDownload = $false
                } else {
                    Write-Warn "Cached file checksum mismatch, re-downloading..."
                    Remove-Item $filePath -Force -ErrorAction SilentlyContinue
                }
            } else {
                Write-Ok "Using cached $fileName (no checksum match in sha256sums.txt)."
                $needDownload = $false
            }
        } else {
            Write-Ok "Using cached $fileName."
            $needDownload = $false
        }
    }

    if ($needDownload) {
        Write-Info "Downloading $fileName..."
        $dlOk = Invoke-DownloadMirror `
            -Path "/$RELEASES_REPO/releases/download/desktop-v$Version/$fileName" `
            -OutFile $filePath -Label "Claude Desktop App"

        if (-not $dlOk) {
            Write-Warn "Desktop App download failed."
            Write-Info "Download manually from: https://github.com/$RELEASES_REPO/releases/tag/desktop-v$Version"
            return
        }

        # Verify checksum after download
        if ($shaOk) {
            $shaContent = Get-Content $shaFile -Raw -ErrorAction SilentlyContinue
            $escapedName = [regex]::Escape($fileName)
            if ($shaContent -match "([a-f0-9]{64})\s+$escapedName") {
                $expected = $Matches[1]
                $actual = (Get-FileHash -Path $filePath -Algorithm SHA256).Hash.ToLower()
                if ($actual -eq $expected) {
                    Write-Ok "SHA-256 verified."
                } else {
                    Write-Warn "Checksum mismatch! File may be corrupted."
                    Remove-Item $filePath -Force -ErrorAction SilentlyContinue
                    return
                }
            }
        }
    }

    Unblock-File -Path $filePath -ErrorAction SilentlyContinue

    Write-Info "Running installer..."
    try {
        $proc = Start-Process -FilePath $filePath -Wait -PassThru -ErrorAction Stop
        if (Test-DesktopInstalled) {
            Write-Ok "Claude Desktop App installed: $env:LOCALAPPDATA\Claude\Claude.exe"
        } else {
            Write-Warn "Installer completed but Claude.exe not found at expected location."
            Write-Info "Setup file saved at: $filePath"
        }
    } catch {
        Write-Warn "Failed to run installer: $($_.Exception.Message)"
        Write-Info "Setup file saved at: $filePath"
    }

    $global:DesktopFile = $filePath
}
```

- [ ] **Step 6: Restructure `Main` to use product selection**

In the `Main` function, add `Select-Product` call after `Get-LatestVersion`:

After line 1051 (`$targetVersion = Get-LatestVersion`), add:

```powershell
    Select-Product
```

Wrap the CLI version check block (lines 1052-1078) with:

```powershell
    if ($global:InstallCli) {
        # ... existing version check code ...
    }
```

Wrap the CLI install method selection (lines 1080-1104) with:

```powershell
    if ($global:InstallCli -and -not $skipInstall) {
        # ... existing method selection code ...
    }
```

Wrap the mirror selection (lines 1107-1110) to also trigger for Desktop:

```powershell
    if ((-not $global:InstalledViaWinget -and $global:InstallCli -and -not $skipInstall) -or $global:InstallDesktop) {
        if (-not $global:SelectedMirror) {
            Select-Mirror -Version $targetVersion
        }
    }
```

Wrap the Git check (line 1113) with:

```powershell
    if ($global:InstallCli) {
        Ensure-Git
    }
```

Wrap the native install block (lines 1115-1262) with:

```powershell
    if ($global:InstallCli -and -not $global:InstalledViaWinget -and -not $global:InstalledViaNpm -and -not $skipInstall) {
        # ... existing native install code ...
    }
```

After the CLI install block, before CC Switch, add Desktop install:

```powershell
    if ($global:InstallDesktop) {
        $desktopNeedsInstall = $true
        if (Test-DesktopInstalled) {
            $overwrite = Read-Host "Desktop App is already installed. Overwrite? [y/N]"
            if ($overwrite -notmatch '^[Yy]') { $desktopNeedsInstall = $false }
        }

        if ($desktopNeedsInstall -and $global:DesktopVersion) {
            Install-DesktopApp -Version $global:DesktopVersion
        }
    }
```

Wrap CC Switch and API Key blocks with CLI check:

```powershell
    if ($global:InstallCli) {
        # 12. Optional: CC Switch
        # ... existing CC Switch code ...

        # 13. API / Provider configuration
        # ... existing API key code ...
    }
```

Add Desktop info to the "Done" section (before `Wait-BeforeExit`):

```powershell
    if ($global:InstallDesktop -and (Test-DesktopInstalled)) {
        Write-Host "  Claude Desktop App: $env:LOCALAPPDATA\Claude\Claude.exe" -ForegroundColor Cyan
        Write-Host ""
    }
```

- [ ] **Step 7: Commit**

```bash
git add install.ps1
git commit -m "Add Desktop App install support to Windows installer

README-based version detection (fixes /releases/latest bug).
Product selection menu, Desktop download with SHA-256 verification,
Squirrel installer execution, conditional Git/CC Switch/API Key flow."
```

---

### Task 7: Add Desktop App uninstall support (uninstall.ps1)

**Files:**
- Modify: `uninstall.ps1`

- [ ] **Step 1: Add Desktop detection in Main**

After `$anthropicKeys` detection (line 359), add:

```powershell
    $desktopExe = "$env:LOCALAPPDATA\Claude\Claude.exe"
    $desktopInstalled = Test-Path $desktopExe
    $desktopEntry = $null
    if ($desktopInstalled) {
        $desktopEntry = Find-RegistryEntry -Patterns @("Claude", "Claude Desktop*")
    }
```

- [ ] **Step 2: Update "nothing installed" check**

Change line 362:

```powershell
    $hasInstall = $isWinget -or $isNpmInstall -or ($foundExes.Count -gt 0) -or $gitEntry -or $nodeEntry
```

to:

```powershell
    $hasInstall = $isWinget -or $isNpmInstall -or ($foundExes.Count -gt 0) -or $gitEntry -or $nodeEntry -or $desktopInstalled
```

- [ ] **Step 3: Add Desktop to detected state display**

After the `$anthropicKeys` display line (line 394), add:

```powershell
    if ($desktopInstalled) {
        $desktopLabel = if ($desktopEntry) { "$($desktopEntry.DisplayName) v$($desktopEntry.DisplayVersion)" } else { $desktopExe }
        Write-Info "Desktop:   $desktopLabel"
    }
```

- [ ] **Step 4: Add Desktop uninstall choice**

After the Node.js choice block, add:

```powershell
    $removeDesktop = $false
    if ($desktopInstalled) {
        $removeDesktop = Ask-YesNo "Remove Claude Desktop App?"
    }
```

- [ ] **Step 5: Update "nothing selected" and summary**

Add `$removeDesktop` to the `$anySelected` check:

```powershell
    $anySelected = $removeWinget -or $removeNpm -or ($removeBinaries.Count -gt 0) -or $removeCache -or $removeConfig `
                   -or $removeCcSwitch -or $removeAnthropicEnv -or $removeGit -or $removeNode -or $removeDesktop
```

Add to summary:

```powershell
    if ($removeDesktop) { Write-Host "  - Claude Desktop App ($env:LOCALAPPDATA\Claude\)" }
```

- [ ] **Step 6: Add Desktop removal execution**

After the Node.js removal block (before the final "Uninstall complete" message), add:

```powershell
    if ($removeDesktop) {
        Write-Info "Removing Claude Desktop App..."
        if ($desktopEntry -and $desktopEntry.UninstallString) {
            try {
                $uninstStr = $desktopEntry.UninstallString
                $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$uninstStr`"" `
                    -Wait -PassThru -ErrorAction Stop
                if ($proc.ExitCode -eq 0) {
                    Write-Ok "Claude Desktop App uninstalled."
                } else {
                    Write-Warn "Uninstaller exited with code $($proc.ExitCode). Trying direct removal..."
                    Remove-Item "$env:LOCALAPPDATA\Claude" -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Ok "Removed: $env:LOCALAPPDATA\Claude\"
                }
            } catch {
                Write-Warn "Uninstall failed: $($_.Exception.Message). Trying direct removal..."
                Remove-Item "$env:LOCALAPPDATA\Claude" -Recurse -Force -ErrorAction SilentlyContinue
                Write-Ok "Removed: $env:LOCALAPPDATA\Claude\"
            }
        } else {
            Remove-Item "$env:LOCALAPPDATA\Claude" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Ok "Removed: $env:LOCALAPPDATA\Claude\"
        }
        # Clean cached Desktop setup files
        Get-ChildItem "$DOWNLOAD_CACHE\ClaudeSetup-*" -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item $_.FullName -Force; Write-Info "  Cleaned cache: $($_.Name)" }
        Write-Info "Desktop App user data (if any): $env:APPDATA\Claude\"
    }
```

- [ ] **Step 7: Commit**

```bash
git add uninstall.ps1
git commit -m "Add Desktop App detection and uninstall support for Windows

Detects via registry and %LOCALAPPDATA%\Claude. Uses UninstallString if available,
falls back to directory removal. Cleans cached setup files, prints user data path."
```

---

### Task 8: Update tests (test.sh)

**Files:**
- Modify: `tests/test.sh`

- [ ] **Step 1: Update layer 2 `get_latest_version` test**

Replace the existing `get_latest_version` test (lines 62-68) with:

```bash
    # get_latest_version (README-based, returns both CLI and Desktop versions)
    local version desktop_version
    version="$(bash -c "source '${INSTALL_SH}'; get_latest_version; echo \$VERSION" 2>/dev/null | tail -1)"
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        pass "get_latest_version → CLI v${version}"
    else
        fail "get_latest_version CLI 返回非预期值: '${version}'"
    fi

    desktop_version="$(bash -c "source '${INSTALL_SH}'; get_latest_version; echo \$DESKTOP_VERSION" 2>/dev/null | tail -1)"
    if [[ "$desktop_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        pass "get_latest_version → Desktop v${desktop_version}"
    else
        fail "get_latest_version Desktop 返回非预期值: '${desktop_version}'"
    fi
```

- [ ] **Step 2: Add layer 3 product menu tests**

After the npm install test in layer 3, add:

```bash
    # 模拟：Linux 上 select_product 应跳过菜单，INSTALL_DESKTOP=false
    local product_linux_out
    product_linux_out="$(bash -c "
        source '${INSTALL_SH}'
        PLATFORM='linux-x64'
        DESKTOP_VERSION='1.5354.0'
        select_product
        echo \"CLI=\$INSTALL_CLI\"
        echo \"DESKTOP=\$INSTALL_DESKTOP\"
    " 2>/dev/null)"
    if echo "$product_linux_out" | grep -q "^CLI=true$" &&
       echo "$product_linux_out" | grep -q "^DESKTOP=false$"; then
        pass "Linux: select_product → CLI=true, DESKTOP=false（菜单跳过）"
    else
        fail "Linux select_product 异常: '${product_linux_out}'"
    fi

    # 模拟：DESKTOP_VERSION 为空时 select_product 应只装 CLI
    local product_nodesktop_out
    product_nodesktop_out="$(bash -c "
        source '${INSTALL_SH}'
        PLATFORM='darwin-arm64'
        DESKTOP_VERSION=''
        select_product
        echo \"CLI=\$INSTALL_CLI\"
        echo \"DESKTOP=\$INSTALL_DESKTOP\"
    " 2>/dev/null)"
    if echo "$product_nodesktop_out" | grep -q "^CLI=true$" &&
       echo "$product_nodesktop_out" | grep -q "^DESKTOP=false$"; then
        pass "macOS + no DESKTOP_VERSION: select_product → CLI only"
    else
        fail "macOS no DESKTOP_VERSION select_product 异常: '${product_nodesktop_out}'"
    fi
```

- [ ] **Step 3: Run all non-Docker tests**

Run: `bash tests/test.sh 1 2 3`
Expected: All PASS

- [ ] **Step 4: Commit**

```bash
git add tests/test.sh
git commit -m "Update tests for README-based version parser and product selection

Layer 2: verify get_latest_version returns both CLI and Desktop versions.
Layer 3: verify select_product skips menu on Linux and when Desktop version unavailable."
```

---

### Task 9: Update documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`
- Modify: `tests/TESTING.md`

- [ ] **Step 1: Update CLAUDE.md**

In `CLAUDE.md`, update the `install.sh 核心流程` section to include Desktop steps:

After `选择安装方式` line, add:

```
select_product           # 产品选择：CLI / Desktop / Both（Linux 跳过）
```

Add a new section after the `npm 安装路径` section:

```markdown
### Desktop App 安装

- 仅 macOS 和 Windows 支持（Linux 无 Desktop App）
- 版本检测：从 README 解析 `desktop-v*` 版本号（和 CLI 版本同一请求获取）
- 下载来源：`$MIRROR/ProjectAILeap/claude-code-releases/releases/download/desktop-v$VERSION/{filename}`
- 校验：`sha256sums.txt`（同一 release 中）
- macOS 安装：`hdiutil attach` → `cp -R *.app /Applications/` → `hdiutil detach` → `xattr -cr`
- Windows 安装：运行 `ClaudeSetup-{ver}-{platform}.exe`（Squirrel，无需管理员权限）
- 只装 Desktop 时跳过 Git 检查、CC Switch、API Key 配置
```

Update the `## 与官网安装脚本的差异` table to add Desktop App row:

```markdown
| Desktop App | 无 | macOS / Windows 安装支持 |
```

- [ ] **Step 2: Update README.md**

Add Desktop App usage after CLI installation instructions. Add note about Linux limitation.

- [ ] **Step 3: Update tests/TESTING.md**

Add new test coverage points to the coverage list:

```markdown
- 第 2 层：`get_latest_version`（README 解析 CLI + Desktop 版本）
- 第 3 层：`select_product` 产品选择（Linux 跳过 / Desktop 版本为空）
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md tests/TESTING.md
git commit -m "Update docs for Desktop App install support

CLAUDE.md: add Desktop App section, update core flow and comparison table.
README.md: add Desktop App usage instructions.
TESTING.md: update test coverage points."
```

---

### Task 10: Manual verification

- [ ] **Step 1: Run full test suite (non-Docker)**

Run: `bash tests/test.sh 1 2 3`
Expected: All PASS

- [ ] **Step 2: Run Docker tests**

Run: `bash tests/test.sh 4 6`
Expected: All PASS (layer 4 Docker + layer 6 upgrade detection)

- [ ] **Step 3: Verify macOS Desktop install manually (if on macOS)**

Run `bash install.sh`, select [2] Desktop App, verify:
- DMG downloads from mirror
- SHA-256 verified
- .app copied to /Applications
- App launches

- [ ] **Step 4: Verify macOS Desktop uninstall manually (if on macOS)**

Run `bash uninstall.sh`, verify Desktop App removal is offered and works.

- [ ] **Step 5: Final commit (if any fixups needed)**

```bash
git add -A
git commit -m "Fix issues found during manual verification"
```
