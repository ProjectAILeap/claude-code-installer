#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Code Windows Uninstaller — ProjectAILeap
.DESCRIPTION
    Interactively removes Claude Code components installed by install.ps1.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$INSTALL_DIR      = "$env:LOCALAPPDATA\Programs\ClaudeCode"
$CLAUDE_EXE       = "$INSTALL_DIR\claude.exe"
$VERSION_FILE     = "$INSTALL_DIR\version.txt"
$CLAUDE_CONFIG_DIR  = "$env:USERPROFILE\.claude"
$CLAUDE_CONFIG_FILE = "$env:USERPROFILE\.claude.json"
$CC_SWITCH_NAME   = "CC Switch"

function Write-Step { param($msg) Write-Host "`n▶ $msg" -ForegroundColor Cyan }
function Write-Ok   { param($msg) Write-Host "  [ OK ]  $msg" -ForegroundColor Green }
function Write-Info { param($msg) Write-Host "  [INFO]  $msg" -ForegroundColor Gray }
function Write-Warn { param($msg) Write-Host "  [WARN]  $msg" -ForegroundColor Yellow }

function Ask-YesNo {
    param([string]$Prompt)
    $ans = Read-Host "$Prompt [y/N]"
    return ($ans -match '^[Yy]')
}

function Remove-FromUserPath {
    param([string]$Dir)
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts   = $current -split ";" | Where-Object { $_ -ne $Dir -and $_ -ne "" }
    $newPath = $parts -join ";"
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    Write-Ok "Removed from user PATH: $Dir"
}

function Uninstall-CcSwitch {
    Write-Info "Looking for CC Switch in Programs..."
    $cc = Get-ItemProperty `
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*CC Switch*" } |
        Select-Object -First 1

    if (-not $cc) {
        Write-Warn "CC Switch not found in installed programs."
        return
    }

    Write-Info "Found: $($cc.DisplayName) v$($cc.DisplayVersion)"
    try {
        $proc = Start-Process -FilePath "msiexec.exe" `
            -ArgumentList "/x `"$($cc.PSChildName)`" /qn /norestart" `
            -Wait -PassThru -ErrorAction Stop
        if ($proc.ExitCode -eq 0) {
            Write-Ok "CC Switch uninstalled."
        } else {
            Write-Warn "msiexec exited with code $($proc.ExitCode)."
            Write-Info "Uninstall string: $($cc.UninstallString)"
        }
    } catch {
        Write-Warn "Failed to uninstall CC Switch: $($_.Exception.Message)"
    }
}

function Main {
    Write-Host ""
    Write-Host "━━━ Claude Code Windows Uninstaller ━━━  ProjectAILeap" -ForegroundColor Cyan
    Write-Host ""

    # Detect installation
    $installedVersion = ""
    if (Test-Path $VERSION_FILE) {
        $installedVersion = (Get-Content $VERSION_FILE -Raw).Trim()
    }

    $hasInstall = (Test-Path $CLAUDE_EXE) -or $installedVersion

    if (-not $hasInstall) {
        Write-Warn "Claude Code does not appear to be installed."
        Write-Info "Nothing to remove."
        exit 0
    }

    Write-Step "Detected installation"
    if ($installedVersion) { Write-Info "  Version:     v$installedVersion" }
    if (Test-Path $CLAUDE_EXE) { Write-Info "  Binary:      $CLAUDE_EXE" }
    Write-Info "  Install dir: $INSTALL_DIR"
    Write-Info "  Config dir:  $CLAUDE_CONFIG_DIR"
    Write-Host ""

    # Collect choices
    $removeBinary   = $false
    $removeDir      = $false
    $removePath     = $false
    $removeConfig   = $false
    $removeCcSwitch = $false

    if (Test-Path $CLAUDE_EXE) {
        $removeBinary = Ask-YesNo "Remove Claude Code binary ($CLAUDE_EXE)?"
    }

    if (Test-Path $INSTALL_DIR) {
        $removeDir = Ask-YesNo "Remove install directory ($INSTALL_DIR)?"
    }

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -and $userPath.Contains($INSTALL_DIR)) {
        $removePath = Ask-YesNo "Remove $INSTALL_DIR from user PATH?"
    }

    if ((Test-Path $CLAUDE_CONFIG_DIR) -or (Test-Path $CLAUDE_CONFIG_FILE)) {
        $removeConfig = Ask-YesNo "Remove Claude configuration (~\.claude\ and ~\.claude.json)?"
    }

    # Check CC Switch
    $cc = Get-ItemProperty `
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*CC Switch*" } |
        Select-Object -First 1

    if ($cc) {
        $removeCcSwitch = Ask-YesNo "Remove CC Switch ($($cc.DisplayName) v$($cc.DisplayVersion))?"
    }

    # Summary
    $anySelected = $removeBinary -or $removeDir -or $removePath -or $removeConfig -or $removeCcSwitch
    if (-not $anySelected) {
        Write-Host "`nNothing selected. Exiting."
        exit 0
    }

    Write-Host ""
    Write-Host "The following will be removed:" -ForegroundColor Yellow
    if ($removeBinary)   { Write-Host "  - Binary:      $CLAUDE_EXE" }
    if ($removeDir)      { Write-Host "  - Install dir: $INSTALL_DIR" }
    if ($removePath)     { Write-Host "  - PATH entry:  $INSTALL_DIR" }
    if ($removeConfig)   { Write-Host "  - Config:      $CLAUDE_CONFIG_DIR  +  $CLAUDE_CONFIG_FILE" }
    if ($removeCcSwitch) { Write-Host "  - CC Switch" }
    Write-Host ""

    if (-not (Ask-YesNo "Proceed?")) {
        Write-Host "`nCancelled."
        exit 0
    }

    # Execute
    Write-Step "Removing..."

    if ($removeBinary -and (Test-Path $CLAUDE_EXE)) {
        Get-Process -Name "claude" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Remove-Item $CLAUDE_EXE -Force
        Write-Ok "Removed: $CLAUDE_EXE"
    }

    if ($removeDir -and (Test-Path $INSTALL_DIR)) {
        Remove-Item $INSTALL_DIR -Recurse -Force
        Write-Ok "Removed: $INSTALL_DIR"
    }

    if ($removePath) {
        Remove-FromUserPath $INSTALL_DIR
    }

    if ($removeConfig) {
        if (Test-Path $CLAUDE_CONFIG_DIR)  { Remove-Item $CLAUDE_CONFIG_DIR  -Recurse -Force; Write-Ok "Removed: $CLAUDE_CONFIG_DIR" }
        if (Test-Path $CLAUDE_CONFIG_FILE) { Remove-Item $CLAUDE_CONFIG_FILE -Force;          Write-Ok "Removed: $CLAUDE_CONFIG_FILE" }
    }

    if ($removeCcSwitch) {
        Uninstall-CcSwitch
    }

    Write-Host ""
    Write-Host "  Uninstall complete." -ForegroundColor Green
    Write-Host ""
}

Main
