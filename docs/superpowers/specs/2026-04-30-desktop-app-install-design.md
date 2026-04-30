# Design: Claude Desktop App Install Support

## Overview

Extend `claude-code-installer` to support installing and uninstalling the Claude Desktop App alongside the existing Claude Code CLI. Desktop App binaries are already archived in `ProjectAILeap/claude-code-releases` under `desktop-v*` tags.

**Constraints:**
- Desktop App has no Linux version (API explicitly rejects it)
- Desktop App uses OAuth (claude.ai account), not API Key
- Desktop App has its own auto-update mechanism (Squirrel)

## Approach

Add Desktop App logic directly into existing scripts (`install.sh`, `install.ps1`, `uninstall.sh`, `uninstall.ps1`). No new scripts, no lib extraction. Preserves single-file `curl | bash` execution model.

## Interaction Flow

### Product Selection Menu (new step, before install method selection)

**macOS / Windows:**
```
What would you like to install?
  [1] Claude Code (CLI)
  [2] Claude Desktop App
  [3] Both

Enter choice [1]:
```

**Linux:** Menu skipped entirely. Only CLI is available. Existing behavior unchanged.

Control variables: `INSTALL_CLI` and `INSTALL_DESKTOP` (booleans).

### Conditional Step Execution

| Step | CLI only | Desktop only | Both |
|------|----------|-------------|------|
| Product selection menu | [1] | [2] | [3] |
| CLI install method selection | Yes | Skip | Yes |
| Git check | Yes | Skip | Yes |
| Mirror speed test | Yes (binary) | Yes | Yes |
| CLI download + install | Yes | Skip | Yes |
| Desktop download + install | Skip | Yes | Yes |
| CC Switch prompt | Yes | Skip | Yes |
| API Key configuration | Yes | Skip | Yes |

Desktop install executes after CLI install when both are selected. Mirror speed test runs once and results are shared via `MIRROR_ORDER`.

## Version Detection

### Fetching Versions from README (CLI + Desktop)

The `claude-code-releases` README contains a structured version table between `<!-- LATEST_VERSIONS_START -->` and `<!-- LATEST_VERSIONS_END -->` markers:

```markdown
| **Claude Code CLI** | `v2.1.123` | 2026-04-30 | [Release](../../releases/tag/v2.1.123) |
| **Claude Desktop App** | `v1.5354.0` | 2026-04-30 | [Release](../../releases/tag/desktop-v1.5354.0) |
```

Fetch raw README in a single request, parse both versions:

```
GET https://raw.githubusercontent.com/ProjectAILeap/claude-code-releases/main/README.md
```

- CLI version: grep for `releases/tag/v` (excluding `desktop-v`), extract version number → `VERSION`
- Desktop version: grep for `releases/tag/desktop-v`, extract version number → `DESKTOP_VERSION`

**This replaces the existing `/releases/latest` API call for CLI version detection.** The current approach is broken: `/releases/latest` now returns the Desktop release (`desktop-v1.5354.0`) instead of the CLI release, because GitHub's "latest" always points to the most recently created release regardless of tag prefix.

**Fallback:** If raw README fetch fails, fall back to `/releases?per_page=10` API and filter by tag prefix (`v*` for CLI, `desktop-v*` for Desktop).

**Mirror support:** The raw README URL goes through `raw.githubusercontent.com`, which may be blocked. Try the fastest GitHub mirror first:
```
{MIRROR}/ProjectAILeap/claude-code-releases/raw/main/README.md
```
If all mirrors fail, try the API fallback.

### Installed Detection (no version comparison)

| Platform | Check |
|----------|-------|
| macOS | `[ -d "/Applications/Claude.app" ]` |
| Windows | `Test-Path "$env:LOCALAPPDATA\Claude\Claude.exe"` or registry |

No version comparison. If already installed, prompt "Desktop App is already installed. Overwrite? [y/N]". User can skip.

## Download

### Asset Naming

| Platform | Filename |
|----------|----------|
| macOS | `Claude-{ver}-darwin-universal.dmg` |
| Windows x64 | `ClaudeSetup-{ver}-win32-x64.exe` |
| Windows ARM64 | `ClaudeSetup-{ver}-win32-arm64.exe` |

### Download URL

```
{MIRROR}/ProjectAILeap/claude-code-releases/releases/download/desktop-v{ver}/{filename}
```

Reuses `MIRROR_ORDER` array, tries each mirror in order. Same pattern as CLI binary download.

### Checksum Verification

Download `sha256sums.txt` from the same release. Format: `{hash}  {filename}`. Parse with grep for the target filename, compare with `sha256sum` / `shasum`.

### Cache

Cache files in `~/.claude/downloads/` (same directory as CLI binary cache). Filenames include version, no collision with CLI files. On re-run, skip download if cached file exists and checksum matches.

## Installation

### macOS (install.sh)

```bash
# 1. Mount DMG
hdiutil attach "{dmg_file}" -nobrowse -quiet
# Parse actual mount point from hdiutil output (don't hardcode /Volumes/Claude)

# 2. Find .app in mount point
# Use find to locate *.app (don't hardcode Claude.app)

# 3. Copy to /Applications (overwrite existing)
cp -R "{found_app}" /Applications/

# 4. Unmount
hdiutil detach "{mount_point}" -quiet

# 5. Remove quarantine attribute (use the actual app name found in step 2)
xattr -cr "/Applications/${app_name}" 2>/dev/null || true
```

**Error handling:** If `hdiutil attach` fails, print cached DMG path and suggest manual install.

### Windows (install.ps1)

```powershell
# 1. Run Squirrel installer (installs to %LOCALAPPDATA%\Claude\)
Start-Process -FilePath "{exe_file}" -Wait -PassThru

# 2. Verify
Test-Path "$env:LOCALAPPDATA\Claude\Claude.exe"
```

No admin rights needed (Squirrel installs to user directory). No silent flags (Squirrel auto-installs without interaction). On failure, print cached EXE path and suggest manual install.

## Uninstall

### macOS (uninstall.sh)

Detection: `[ -d "/Applications/Claude.app" ]`

Interactive prompt (consistent with CC Switch uninstall style):
```
Remove Claude Desktop App (/Applications/Claude.app)? [y/N]
```

Actions:
- `rm -rf "/Applications/Claude.app"`
- Clean up cached Desktop DMG files from `~/.claude/downloads/`

### Windows (uninstall.ps1)

Detection:
1. Registry: `Find-RegistryEntry -Patterns @("Claude", "Claude Desktop*")`
2. Fallback: `Test-Path "$env:LOCALAPPDATA\Claude\"`

Actions:
- If registry entry found: run `UninstallString` from registry
- If only directory found: delete `$env:LOCALAPPDATA\Claude\`

### User Data (NOT deleted)

Desktop App user data (`~/.config/Claude/` on macOS, `%APPDATA%\Claude\` on Windows) is not deleted. Print path at end for user reference.

## Testing

### test.sh additions

- **Layer 2 (unit tests):** `get_versions_from_readme` — verify README parsing extracts both CLI (`VERSION`) and Desktop (`DESKTOP_VERSION`) correctly; verify fallback to API when README fetch fails
- **Layer 3 (logic simulation):** Verify product menu is hidden on Linux; verify menu shows 3 options on macOS (simulated)
- No Docker integration tests for Desktop (hdiutil is macOS-only, no value in container)
- Update existing `get_latest_version` tests to reflect new README-based approach

### test.ps1 additions

- **Layer 2 (unit tests):** Version fetch from README (both CLI and Desktop)
- **Layer 3 (logic simulation):** Product selection logic, platform detection (x64 vs ARM64 → correct EXE filename)

## Documentation Updates

- **CLAUDE.md:** Update script descriptions, add Desktop App section to core flow, note platform limitations
- **README.md:** Add Desktop App install usage, note Linux limitation
- **TESTING.md:** Update coverage table with new test points
