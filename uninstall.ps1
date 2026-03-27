<#
.SYNOPSIS
    Claude Code Windows Uninstaller -- ProjectAILeap
.DESCRIPTION
    Interactively removes Claude Code components installed by install.ps1.
    Handles both install locations:
      - Official: ~/.local/bin/claude.exe  (via claude install)
      - Fallback: %LOCALAPPDATA%\Programs\ClaudeCode\claude.exe
    Also handles: PATH, config, downloads cache, CC Switch, ANTHROPIC_* env vars.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$OutputEncoding           = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Install location (official: claude install, and our fallback both use this path)
$LOCAL_BIN         = "$env:USERPROFILE\.local\bin"
$CLAUDE_EXE        = "$LOCAL_BIN\claude.exe"
$DOWNLOAD_CACHE    = "$env:USERPROFILE\.claude\downloads"
$CLAUDE_CONFIG_DIR = "$env:USERPROFILE\.claude"
$CLAUDE_CONFIG_FILE = "$env:USERPROFILE\.claude.json"

function Write-Step { param($msg) Write-Host "`n>> $msg" -ForegroundColor Cyan }
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
    if ($null -eq $current) { return }
    $parts = $current -split ";" | Where-Object { $_ -ne $Dir -and $_ -ne "" }
    [Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), "User")
    Write-Ok "Removed from user PATH: $Dir"
}

function Remove-AnthropicEnv {
    @("ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL") | ForEach-Object {
        $val = [Environment]::GetEnvironmentVariable($_, "User")
        if ($val) {
            [Environment]::SetEnvironmentVariable($_, $null, "User")
            Write-Ok "Removed user env: $_"
        }
    }
}

function Find-Git {
    $paths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    return Get-ItemProperty $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and
            ($_.DisplayName -like "Git version *" -or $_.DisplayName -eq "Git" -or
             $_.DisplayName -like "Git for Windows*") } |
        Select-Object -First 1
}

function Uninstall-Git {
    param($GitEntry)
    Write-Info "Uninstalling Git for Windows..."
    try {
        # Git for Windows uses Inno Setup; UninstallString points to unins000.exe
        $uninstExe = $GitEntry.UninstallString -replace '"', '' -replace '/[A-Z].*$', '' -replace '\s+$', ''
        if (-not (Test-Path $uninstExe)) {
            # Fallback: look for unins000.exe next to git.exe
            $gitCmd = Get-Command git -ErrorAction SilentlyContinue
            $gitExe = if ($gitCmd) { $gitCmd.Source } else { $null }
            if ($gitExe) {
                $uninstExe = Join-Path (Split-Path (Split-Path $gitExe -Parent) -Parent) "unins000.exe"
            }
        }
        if (Test-Path $uninstExe) {
            $proc = Start-Process -FilePath $uninstExe `
                -ArgumentList "/VERYSILENT /NORESTART /SUPPRESSMSGBOXES" `
                -Wait -PassThru -NoNewWindow -ErrorAction Stop
            if ($proc.ExitCode -eq 0) {
                Write-Ok "Git uninstalled."
            } else {
                Write-Warn "Git uninstaller exited with code $($proc.ExitCode)."
            }
        } else {
            Write-Warn "Could not locate Git uninstaller. Please uninstall manually."
        }
    } catch {
        Write-Warn "Failed to uninstall Git: $($_.Exception.Message)"
    }
}

function Find-CcSwitch {
    $registryPaths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    return Get-ItemProperty $registryPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like "*CC Switch*" } |
        Select-Object -First 1
}

function Uninstall-CcSwitch {
    param($CcEntry)
    Write-Info "Uninstalling CC Switch..."
    try {
        $productCode = $CcEntry.PSChildName
        if ($productCode -match '^\{') {
            $proc = Start-Process -FilePath "msiexec.exe" `
                -ArgumentList "/x `"$productCode`" /qn /norestart" `
                -Wait -PassThru -ErrorAction Stop
        } else {
            $uninstStr = $CcEntry.UninstallString
            $proc = Start-Process -FilePath "msiexec.exe" `
                -ArgumentList ($uninstStr -replace 'msiexec\.exe\s*', '') + " /qn /norestart" `
                -Wait -PassThru -ErrorAction Stop
        }
        if ($proc.ExitCode -eq 0) {
            Write-Ok "CC Switch uninstalled."
        } else {
            Write-Warn "msiexec exited with code $($proc.ExitCode)."
        }
    } catch {
        Write-Warn "Failed to uninstall CC Switch: $($_.Exception.Message)"
    }
}

function Get-WingetExe {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $localLink = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"
    if (Test-Path $localLink) { return $localLink }
    $pkg = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($pkg) {
        $exe = Join-Path $pkg.InstallLocation "winget.exe"
        if (Test-Path $exe) { return $exe }
    }
    return $null
}

function Uninstall-ViaWinget {
    param([string]$WingetExe)
    Write-Info "Uninstalling Claude Code via winget..."
    try {
        $proc = Start-Process $WingetExe `
            -ArgumentList "uninstall --id Anthropic.ClaudeCode --silent --exact" `
            -Wait -PassThru -ErrorAction Stop
        if ($proc.ExitCode -eq 0) {
            Write-Ok "Claude Code uninstalled via winget."
        } else {
            Write-Warn "winget uninstall exited with code $($proc.ExitCode)."
        }
    } catch {
        Write-Warn "winget uninstall failed: $($_.Exception.Message)"
    }
}

function Main {
    Write-Host ""
    Write-Host "=== Claude Code Windows Uninstaller ===  ProjectAILeap" -ForegroundColor Cyan
    Write-Host ""

    # Detect winget-managed installation
    $isWinget = $false
    $wingetExe = Get-WingetExe
    if ($wingetExe) {
        $wingetList = & $wingetExe list --id Anthropic.ClaudeCode --exact 2>$null
        $isWinget = ($wingetList -match "Anthropic\.ClaudeCode")
    }

    # Detect native install location; also check Get-Command, but only if in a user-writable directory
    # (avoids touching system shims in C:\Windows\system32 left by npm or other tools)
    $foundExes = @()
    if (Test-Path $CLAUDE_EXE) { $foundExes += $CLAUDE_EXE }
    $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($claudeCmd) {
        $src = $claudeCmd.Source
        $isUserPath = $src -like "$env:USERPROFILE\*" -or $src -like "$env:LOCALAPPDATA\*" -or $src -like "$env:APPDATA\*"
        if ($isUserPath -and ($foundExes -notcontains $src)) {
            $foundExes += $src
        } elseif (-not $isUserPath) {
            Write-Info "Note: claude also found at $src (system/npm path, not managed here -- skipping)"
        }
    }

    $hasInstall = $isWinget -or ($foundExes.Count -gt 0)
    if (-not $hasInstall) {
        Write-Warn "Claude Code does not appear to be installed."
        Write-Info "Nothing to remove."
        exit 0
    }

    # Detect version
    $installedVersion = ""
    if ($claudeCmd) {
        try {
            $out = & $claudeCmd.Source --version 2>&1
            if ("$out" -match '(\d+\.\d+\.\d+)') { $installedVersion = $Matches[1] }
        } catch {}
    }

    # Detect other components
    $ccEntry      = Find-CcSwitch
    $gitEntry     = Find-Git
    $userPath     = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($null -eq $userPath) { $userPath = "" }
    $anthropicKeys = @("ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL") |
        Where-Object { $null -ne [Environment]::GetEnvironmentVariable($_, "User") }

    Write-Step "Detected installation"
    if ($isWinget)         { Write-Info "winget:   Claude Code (Anthropic.ClaudeCode)" }
    if ($installedVersion) { Write-Info "Version:  v$installedVersion" }
    foreach ($exe in $foundExes) { Write-Info "Binary:   $exe" }
    if (Test-Path $DOWNLOAD_CACHE) { Write-Info "Cache:    $DOWNLOAD_CACHE" }
    if ($ccEntry)  { Write-Info "CC Switch: $($ccEntry.DisplayName) v$($ccEntry.DisplayVersion)" }
    if ($gitEntry) { Write-Info "Git:       $($gitEntry.DisplayName)" }
    if ($anthropicKeys) { Write-Info "ANTHROPIC_*: $($anthropicKeys -join ', ') (user env)" }
    Write-Host ""

    # Collect choices
    $removeWinget      = $false
    $removeBinaries    = @()
    $removeDirs        = @()
    $removePathDirs    = @()
    $removeCache       = $false
    $removeConfig      = $false
    $removeCcSwitch    = $false
    $removeAnthropicEnv = $false
    $removeGit         = $false

    if ($isWinget) {
        $removeWinget = Ask-YesNo "Remove Claude Code (winget)?"
    }

    foreach ($exe in $foundExes) {
        if (Ask-YesNo "Remove Claude Code binary ($exe)?") {
            $removeBinaries += $exe
            $dir = Split-Path $exe -Parent
            if (Test-Path $dir) {
                if (Ask-YesNo "  Also remove directory ($dir)?") {
                    $removeDirs += $dir
                }
            }
            if ($userPath.Contains($dir) -and ($removePathDirs -notcontains $dir)) {
                if (Ask-YesNo "  Remove $dir from user PATH?") {
                    $removePathDirs += $dir
                }
            }
        }
    }

    if (Test-Path $DOWNLOAD_CACHE) {
        $removeCache = Ask-YesNo "Remove downloads cache ($DOWNLOAD_CACHE)?"
    }
    if ((Test-Path $CLAUDE_CONFIG_DIR) -or (Test-Path $CLAUDE_CONFIG_FILE)) {
        $removeConfig = Ask-YesNo "Remove Claude configuration (~\.claude\ and ~\.claude.json)?"
    }
    if ($ccEntry) {
        $removeCcSwitch = Ask-YesNo "Remove CC Switch ($($ccEntry.DisplayName) v$($ccEntry.DisplayVersion))?"
    }
    if ($anthropicKeys) {
        $removeAnthropicEnv = Ask-YesNo "Remove ANTHROPIC_* variables from user environment ($($anthropicKeys -join ', '))?"
    }
    if ($gitEntry) {
        $removeGit = Ask-YesNo "Remove Git for Windows ($($gitEntry.DisplayName))? [default: No]"
    }

    # Check anything selected
    $anySelected = $removeWinget -or ($removeBinaries.Count -gt 0) -or $removeCache -or $removeConfig `
                   -or $removeCcSwitch -or $removeAnthropicEnv -or $removeGit
    if (-not $anySelected) {
        Write-Host "`nNothing selected. Exiting."
        exit 0
    }

    # Summary
    Write-Host ""
    Write-Host "The following will be removed:" -ForegroundColor Yellow
    if ($removeWinget)                 { Write-Host "  - Claude Code (winget)" }
    foreach ($exe in $removeBinaries)  { Write-Host "  - Binary:    $exe" }
    foreach ($dir in $removeDirs)      { Write-Host "  - Directory: $dir" }
    foreach ($dir in $removePathDirs)  { Write-Host "  - PATH entry: $dir" }
    if ($removeCache)       { Write-Host "  - Cache:     $DOWNLOAD_CACHE" }
    if ($removeConfig)      { Write-Host "  - Config:    $CLAUDE_CONFIG_DIR  +  $CLAUDE_CONFIG_FILE" }
    if ($removeCcSwitch)    { Write-Host "  - CC Switch" }
    if ($removeAnthropicEnv) { Write-Host "  - ANTHROPIC_* user environment variables" }
    if ($removeGit)         { Write-Host "  - Git for Windows ($($gitEntry.DisplayName))" }
    Write-Host ""

    if (-not (Ask-YesNo "Proceed?")) {
        Write-Host "`nCancelled."
        exit 0
    }

    Write-Step "Removing..."

    if ($removeWinget) { Uninstall-ViaWinget -WingetExe $wingetExe }

    foreach ($exe in $removeBinaries) {
        if (Test-Path $exe) {
            Get-Process -Name "claude" -ErrorAction SilentlyContinue |
                Stop-Process -Force -ErrorAction SilentlyContinue
            Remove-Item $exe -Force
            Write-Ok "Removed: $exe"
        }
    }

    foreach ($dir in $removeDirs) {
        if (Test-Path $dir) {
            Remove-Item $dir -Recurse -Force
            Write-Ok "Removed: $dir"
        }
    }

    foreach ($dir in $removePathDirs) {
        Remove-FromUserPath $dir
    }

    if ($removeCache -and (Test-Path $DOWNLOAD_CACHE)) {
        Remove-Item $DOWNLOAD_CACHE -Recurse -Force
        Write-Ok "Removed: $DOWNLOAD_CACHE"
    }

    if ($removeConfig) {
        if (Test-Path $CLAUDE_CONFIG_DIR) {
            Remove-Item $CLAUDE_CONFIG_DIR -Recurse -Force
            Write-Ok "Removed: $CLAUDE_CONFIG_DIR"
        }
        if (Test-Path $CLAUDE_CONFIG_FILE) {
            Remove-Item $CLAUDE_CONFIG_FILE -Force
            Write-Ok "Removed: $CLAUDE_CONFIG_FILE"
        }
    }

    if ($removeCcSwitch -and $ccEntry) {
        Uninstall-CcSwitch -CcEntry $ccEntry
    }

    if ($removeAnthropicEnv) {
        Remove-AnthropicEnv
    }

    if ($removeGit -and $gitEntry) {
        Uninstall-Git -GitEntry $gitEntry
    }

    Write-Host ""
    Write-Host "  Uninstall complete." -ForegroundColor Green
    Write-Host ""
}

Main
