#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Code Windows Installer — ProjectAILeap
.DESCRIPTION
    Installs or upgrades Claude Code on Windows using official binaries from
    github.com/ProjectAILeap/claude-code-releases (no npm required).
    Supports GitHub mirror acceleration for users in China.
.NOTES
    Source:  https://github.com/ProjectAILeap/claude-code-installer
    Binaries: https://github.com/ProjectAILeap/claude-code-releases
#>

[CmdletBinding()]
param(
    [string]$Version = "",          # Pin a specific version (e.g. "1.2.3")
    [switch]$Force,                 # Force reinstall even if up to date
    [switch]$NoVerify               # Skip SHA-256 checksum verification
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Constants ──────────────────────────────────────────────────────────────
$RELEASES_REPO  = "ProjectAILeap/claude-code-releases"
$INSTALL_DIR    = "$env:LOCALAPPDATA\Programs\ClaudeCode"
$VERSION_FILE   = "$INSTALL_DIR\version.txt"
$CLAUDE_EXE     = "$INSTALL_DIR\claude.exe"

$CC_SWITCH_REPO = "farion1231/cc-switch"

$MIRRORS = @(
    "https://github.com",
    "https://ghfast.top/https://github.com",
    "https://gh-proxy.com/https://github.com",
    "https://mirror.ghproxy.com/https://github.com",
    "https://kkgithub.com"
)

# ── Colors / Output ────────────────────────────────────────────────────────
function Write-Step  { param($msg) Write-Host "`n▶ $msg" -ForegroundColor Cyan }
function Write-Info  { param($msg) Write-Host "  [INFO]  $msg" -ForegroundColor Gray }
function Write-Ok    { param($msg) Write-Host "  [ OK ]  $msg" -ForegroundColor Green }
function Write-Warn  { param($msg) Write-Host "  [WARN]  $msg" -ForegroundColor Yellow }
function Write-Err   { param($msg) Write-Host "  [ERR ]  $msg" -ForegroundColor Red }

function Exit-WithError {
    param($msg)
    Write-Err $msg
    exit 1
}

# ── Mirror selection ───────────────────────────────────────────────────────
$SelectedMirror = ""

function Select-Mirror {
    Write-Step "Selecting fastest mirror..."
    $testPath = "/$RELEASES_REPO/releases"

    foreach ($m in $MIRRORS) {
        $url = "$m$testPath"
        try {
            $resp = Invoke-WebRequest -Uri $url -Method Head `
                -TimeoutSec 8 -UseBasicParsing -ErrorAction Stop
            if ($resp.StatusCode -lt 400) {
                $script:SelectedMirror = $m
                if ($m -eq "https://github.com") {
                    Write-Ok "Direct: github.com"
                } else {
                    Write-Ok "Mirror: $m"
                }
                return
            }
        } catch {
            Write-Info "  Unreachable: $m"
        }
    }

    Exit-WithError "All mirrors failed. Check your network connection."
}

function Get-DownloadUrl {
    param([string]$Path)   # Path starting with /owner/repo/...
    return "$SelectedMirror$Path"
}

# ── Fetch latest version ───────────────────────────────────────────────────
function Get-LatestVersion {
    Write-Step "Fetching latest version..."
    $apiUrl = "https://api.github.com/repos/$RELEASES_REPO/releases/latest"
    $ver = ""

    try {
        $resp = Invoke-RestMethod -Uri $apiUrl -TimeoutSec 12 `
            -Headers @{ Accept = "application/vnd.github.v3+json" } `
            -ErrorAction Stop
        $ver = $resp.tag_name -replace '^v', ''
    } catch {
        Write-Info "GitHub API unavailable, trying fallback..."
    }

    if (-not $ver) {
        # Fallback: parse redirect URL from kkgithub
        try {
            $fallbackUrl = "https://kkgithub.com/$RELEASES_REPO/releases/latest"
            $resp = Invoke-WebRequest -Uri $fallbackUrl -Method Head `
                -TimeoutSec 10 -UseBasicParsing -MaximumRedirection 0 `
                -ErrorAction SilentlyContinue
            $location = $resp.Headers["Location"] ?? ""
            if ($location -match '(\d+\.\d+\.\d+)') {
                $ver = $Matches[1]
            }
        } catch {
            if ($_.Exception.Response) {
                $location = $_.Exception.Response.Headers.Location
                if ($location -and "$location" -match '(\d+\.\d+\.\d+)') {
                    $ver = $Matches[1]
                }
            }
        }
    }

    if (-not $ver) {
        Exit-WithError "Cannot determine latest version. Check network connectivity."
    }

    Write-Info "Latest: v$ver"
    return $ver
}

# ── Installed version ──────────────────────────────────────────────────────
function Get-InstalledVersion {
    if (Test-Path $VERSION_FILE) {
        return (Get-Content $VERSION_FILE -Raw).Trim()
    }
    return ""
}

# ── Download helper with retry ─────────────────────────────────────────────
function Invoke-Download {
    param(
        [string]$Url,
        [string]$OutFile,
        [string]$Label = "file",
        [int]$RetryCount = 3
    )

    for ($i = 1; $i -le $RetryCount; $i++) {
        Write-Info "Downloading $Label (attempt $i/$RetryCount)..."
        Write-Info "  URL: $Url"
        try {
            # Use BITS if available (better progress, resume support)
            if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
                Start-BitsTransfer -Source $Url -Destination $OutFile `
                    -DisplayName "Claude Code" -ErrorAction Stop
            } else {
                $wc = New-Object System.Net.WebClient
                $wc.DownloadFile($Url, $OutFile)
            }
            return $true
        } catch {
            Write-Warn "  Attempt $i failed: $($_.Exception.Message)"
            if ($i -lt $RetryCount) { Start-Sleep -Seconds 2 }
        }
    }
    return $false
}

# ── SHA-256 verification ───────────────────────────────────────────────────
function Test-Checksum {
    param(
        [string]$FilePath,
        [string]$ChecksumFile,
        [string]$FileName
    )

    $content = Get-Content $ChecksumFile -Raw
    $expected = ""

    foreach ($line in ($content -split "`n")) {
        $line = $line.Trim()
        if ($line -match "^([a-f0-9]{64})\s+\*?$FileName") {
            $expected = $Matches[1]
            break
        }
    }

    if (-not $expected) {
        Write-Warn "No checksum entry for $FileName, skipping verification."
        return $true
    }

    $actual = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash.ToLower()

    if ($actual -eq $expected.ToLower()) {
        Write-Ok "SHA-256 verified."
        return $true
    } else {
        Write-Err "Checksum mismatch!"
        Write-Err "  Expected: $expected"
        Write-Err "  Got:      $actual"
        return $false
    }
}

# ── PATH management ────────────────────────────────────────────────────────
function Add-ToUserPath {
    param([string]$Dir)

    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = $currentPath -split ";" | Where-Object { $_ -ne "" }

    if ($parts -contains $Dir) {
        Write-Info "  $Dir already in user PATH."
        return
    }

    $newPath = ($parts + $Dir) -join ";"
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    Write-Ok "Added to user PATH: $Dir"
    Write-Warn "Restart PowerShell to use 'claude' command."
}

# ── Optional: CC Switch ────────────────────────────────────────────────────
function Install-CcSwitch {
    param([string]$Mirror)

    Write-Step "Installing CC Switch (optional)..."

    # Get latest CC Switch version
    $ccVer = ""
    try {
        $ccApi = Invoke-RestMethod -Uri "https://api.github.com/repos/$CC_SWITCH_REPO/releases/latest" `
            -TimeoutSec 10 -ErrorAction Stop
        $ccVer = $ccApi.tag_name -replace '^v', ''
    } catch {
        Write-Warn "Could not fetch CC Switch version from API."
    }

    if (-not $ccVer) {
        Write-Warn "Could not determine CC Switch version."
        Write-Info "Download manually: https://github.com/$CC_SWITCH_REPO/releases"
        return
    }

    $msiName = "CC-Switch-v$ccVer-Windows.msi"
    $msiPath = "$env:TEMP\$msiName"

    # Build URLs with mirror fallback
    $msiUrls = @(
        "$Mirror/$CC_SWITCH_REPO/releases/download/v$ccVer/$msiName",
        "https://ghfast.top/https://github.com/$CC_SWITCH_REPO/releases/download/v$ccVer/$msiName",
        "https://kkgithub.com/$CC_SWITCH_REPO/releases/download/v$ccVer/$msiName",
        "https://github.com/$CC_SWITCH_REPO/releases/download/v$ccVer/$msiName"
    ) | Select-Object -Unique

    $downloaded = $false
    foreach ($url in $msiUrls) {
        if (Invoke-Download -Url $url -OutFile $msiPath -Label "CC Switch MSI") {
            $downloaded = $true
            break
        }
    }

    if (-not $downloaded) {
        Write-Warn "CC Switch download failed."
        Write-Info "Download manually: https://github.com/$CC_SWITCH_REPO/releases"
        return
    }

    Write-Info "Installing CC Switch silently..."
    try {
        $proc = Start-Process -FilePath "msiexec.exe" `
            -ArgumentList "/i `"$msiPath`" /qn /norestart" `
            -Wait -PassThru -ErrorAction Stop
        if ($proc.ExitCode -eq 0) {
            Write-Ok "CC Switch installed."
        } else {
            Write-Warn "CC Switch MSI exited with code $($proc.ExitCode)."
            Write-Info "Try running the MSI manually: $msiPath"
        }
    } catch {
        Write-Warn "Failed to run MSI installer: $($_.Exception.Message)"
        Write-Info "MSI saved to: $msiPath"
    }
}

# ── Main ───────────────────────────────────────────────────────────────────
function Main {
    Write-Host ""
    Write-Host "━━━ Claude Code Windows Installer ━━━  ProjectAILeap" -ForegroundColor Cyan
    Write-Host "Source: github.com/ProjectAILeap/claude-code-releases" -ForegroundColor Gray
    Write-Host ""

    # Resolve target version
    $targetVersion = $Version
    if (-not $targetVersion) {
        $targetVersion = Get-LatestVersion
    } else {
        Write-Info "Pinned version: v$targetVersion"
    }

    # Check installed version
    $installedVersion = Get-InstalledVersion
    if ($installedVersion) {
        if ($installedVersion -eq $targetVersion -and -not $Force) {
            if (Test-Path $CLAUDE_EXE) {
                Write-Ok "Claude Code v$targetVersion is already up to date."
                exit 0
            }
            Write-Info "Binary missing, reinstalling..."
        } elseif ($installedVersion -ne $targetVersion) {
            Write-Info "Upgrading: v$installedVersion → v$targetVersion"
        }
    } else {
        Write-Info "Installing Claude Code v$targetVersion"
    }

    # Mirror selection
    Select-Mirror

    # Prepare install dir
    if (-not (Test-Path $INSTALL_DIR)) {
        New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
    }

    # Download binary
    Write-Step "Downloading claude-$targetVersion-win32-x64.exe..."
    $fileName  = "claude-$targetVersion-win32-x64.exe"
    $dlPath    = "/$RELEASES_REPO/releases/download/v$targetVersion/$fileName"
    $ckPath    = "/$RELEASES_REPO/releases/download/v$targetVersion/sha256sums.txt"
    $dlUrl     = Get-DownloadUrl $dlPath
    $ckUrl     = Get-DownloadUrl $ckPath

    $tmpDir    = [System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid().ToString()
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    $binFile   = "$tmpDir\$fileName"
    $ckFile    = "$tmpDir\sha256sums.txt"

    try {
        if (-not (Invoke-Download -Url $dlUrl -OutFile $binFile -Label "Claude Code binary")) {
            Exit-WithError "Download failed. Try a different mirror or check your connection."
        }

        # Checksum verification
        if (-not $NoVerify) {
            $ckDownloaded = Invoke-Download -Url $ckUrl -OutFile $ckFile -Label "checksums" -RetryCount 2
            if ($ckDownloaded) {
                if (-not (Test-Checksum -FilePath $binFile -ChecksumFile $ckFile -FileName $fileName)) {
                    Exit-WithError "Checksum verification failed. The file may be corrupted."
                }
            } else {
                Write-Warn "Could not download checksums, skipping verification."
            }
        }

        # Install
        Write-Step "Installing..."
        $destExe = $CLAUDE_EXE
        if (Test-Path $destExe) {
            # Kill any running claude process before replacing
            Get-Process -Name "claude" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Remove-Item "$destExe.old" -Force -ErrorAction SilentlyContinue
            Move-Item $destExe "$destExe.old" -Force -ErrorAction SilentlyContinue
        }
        Copy-Item $binFile $destExe -Force
        Remove-Item "$destExe.old" -Force -ErrorAction SilentlyContinue

        Set-Content -Path $VERSION_FILE -Value $targetVersion -Encoding UTF8
        Write-Ok "Installed: $destExe"

    } finally {
        Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # PATH
    Add-ToUserPath $INSTALL_DIR

    # Refresh current session PATH
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "User")

    # Optional: CC Switch
    Write-Host ""
    $installCcSwitch = Read-Host "Install CC Switch (API Provider switcher)? [y/N]"
    if ($installCcSwitch -match '^[Yy]') {
        Install-CcSwitch -Mirror $SelectedMirror
    }

    # Done
    Write-Host ""
    Write-Host "  ✓ Claude Code v$targetVersion installed!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Quick start:"
    Write-Host "    claude            — start Claude Code"
    Write-Host "    claude --version  — verify installation"
    Write-Host ""
    Write-Host "  To upgrade: re-run install.bat"
    Write-Host "  To uninstall: run uninstall.bat"
    Write-Host ""
}

Main
