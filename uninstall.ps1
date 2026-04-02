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
$NPM_PATH_MARKER   = "$env:USERPROFILE\.claude\npm-path-added"
$GIT_INSTALL_MARKER = "$env:USERPROFILE\.claude\git-installed-by-installer"
$NODE_INSTALL_MARKER = "$env:USERPROFILE\.claude\node-installed-by-installer"

function Write-Step { param($msg) Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-Ok   { param($msg) Write-Host "  [ OK ]  $msg" -ForegroundColor Green }
function Write-Info { param($msg) Write-Host "  [INFO]  $msg" -ForegroundColor Gray }
function Write-Warn { param($msg) Write-Host "  [WARN]  $msg" -ForegroundColor Yellow }

function Ask-YesNo {
    param(
        [string]$Prompt,
        [bool]$DefaultYes = $false
    )
    $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    $ans = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($ans)) { return $DefaultYes }
    return ($ans -match '^[Yy]')
}

function Test-InstallerManaged {
    param([string]$MarkerPath)
    return (Test-Path $MarkerPath)
}

function Get-MarkerSignature {
    param([string]$MarkerPath)
    if (-not (Test-Path $MarkerPath)) { return "" }
    try {
        return (Get-Content $MarkerPath -Raw -ErrorAction Stop).Trim()
    } catch {
        return ""
    }
}

function Get-InstallEntrySignature {
    param($Entry)
    if (-not $Entry) { return "" }

    $parts = @()
    if ($Entry.PSChildName)      { $parts += "Key=$($Entry.PSChildName)" }
    if ($Entry.DisplayName)      { $parts += "Name=$($Entry.DisplayName)" }
    if ($Entry.DisplayVersion)   { $parts += "Version=$($Entry.DisplayVersion)" }
    if ($Entry.UninstallString)  { $parts += "Uninstall=$($Entry.UninstallString)" }
    return ($parts -join "`n")
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

function Find-RegistryEntry {
    param(
        [string[]]$Patterns,
        [string]$Signature = ""
    )
    $paths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $entries = Get-ItemProperty $paths -ErrorAction SilentlyContinue |
        Where-Object {
            $entry = $_
            if (-not $entry.PSObject.Properties['DisplayName']) { return $false }
            foreach ($pattern in $Patterns) {
                if ($entry.DisplayName -like $pattern) { return $true }
            }
            return $false
        }

    if ($Signature) {
        $matched = $entries | Where-Object { (Get-InstallEntrySignature $_) -eq $Signature } | Select-Object -First 1
        if ($matched) { return $matched }
    }

    return $entries | Select-Object -First 1
}

function Find-Git {
    param([string]$Signature = "")
    return Find-RegistryEntry -Patterns @("Git version *", "Git", "Git for Windows*") -Signature $Signature
}

function Find-Node {
    param([string]$Signature = "")
    return Find-RegistryEntry -Patterns @("Node.js*", "Node.js LTS*") -Signature $Signature
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
                Remove-Item $GIT_INSTALL_MARKER -Force -ErrorAction SilentlyContinue
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

function Uninstall-Node {
    param($NodeEntry)
    Write-Info "Uninstalling Node.js..."
    try {
        $productCode = $NodeEntry.PSChildName
        if ($productCode -match '^\{') {
            $proc = Start-Process -FilePath "msiexec.exe" `
                -ArgumentList "/x `"$productCode`" /qn /norestart" `
                -Wait -PassThru -ErrorAction Stop
        } else {
            $uninstStr = $NodeEntry.UninstallString
            if ("$uninstStr" -match 'msiexec(\.exe)?') {
                $proc = Start-Process -FilePath "msiexec.exe" `
                    -ArgumentList (($uninstStr -replace '(?i)msiexec(\.exe)?\s*', '') + " /qn /norestart") `
                    -Wait -PassThru -ErrorAction Stop
            } else {
                Write-Warn "Could not determine Node.js uninstall command. Please uninstall manually."
                return
            }
        }
        if ($proc.ExitCode -eq 0) {
            Write-Ok "Node.js uninstalled."
            Remove-Item $NODE_INSTALL_MARKER -Force -ErrorAction SilentlyContinue
        } else {
            Write-Warn "Node.js uninstaller exited with code $($proc.ExitCode)."
        }
    } catch {
        Write-Warn "Failed to uninstall Node.js: $($_.Exception.Message)"
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

    # Detect npm-managed installation (%APPDATA%\npm\claude.cmd placed by npm install -g)
    $isNpmInstall = $false
    $npmBin = "$env:APPDATA\npm"
    if (Test-Path "$npmBin\claude.cmd") { $isNpmInstall = $true }
    if (-not $isNpmInstall -and (Get-Command npm -ErrorAction SilentlyContinue)) {
        try {
            $npmPrefix = (& npm config get prefix 2>$null).Trim()
            if ($npmPrefix -and (Test-Path "$npmPrefix\claude.cmd")) { $isNpmInstall = $true; $npmBin = $npmPrefix }
        } catch {}
    }

    # Detect native install location; also check Get-Command, but only if in a user-writable
    # directory that is NOT the npm bin dir (npm installs are handled separately above).
    $foundExes = @()
    if (Test-Path $CLAUDE_EXE) { $foundExes += $CLAUDE_EXE }
    $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($claudeCmd) {
        $src = $claudeCmd.Source
        $isNpmPath  = $src -like "$env:APPDATA\npm\*"
        $isUserPath = $src -like "$env:USERPROFILE\*" -or $src -like "$env:LOCALAPPDATA\*" -or $src -like "$env:APPDATA\*"
        if ($isNpmPath) {
            # Handled by the npm section — do not add to foundExes
        } elseif ($isUserPath -and ($foundExes -notcontains $src)) {
            $foundExes += $src
        } elseif (-not $isUserPath) {
            Write-Info "Note: claude also found at $src (system path, not managed here -- skipping)"
        }
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
    $installerManagedGit  = Test-InstallerManaged $GIT_INSTALL_MARKER
    $installerManagedNode = Test-InstallerManaged $NODE_INSTALL_MARKER
    $gitSignature  = Get-MarkerSignature $GIT_INSTALL_MARKER
    $nodeSignature = Get-MarkerSignature $NODE_INSTALL_MARKER
    $gitEntry     = Find-Git -Signature $gitSignature
    $nodeEntry    = Find-Node -Signature $nodeSignature
    $userPath     = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($null -eq $userPath) { $userPath = "" }
    $anthropicKeys = @("ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL") |
        Where-Object { $null -ne [Environment]::GetEnvironmentVariable($_, "User") }

    $hasInstall = $isWinget -or $isNpmInstall -or ($foundExes.Count -gt 0) -or `
        ($installerManagedGit -and $gitEntry) -or ($installerManagedNode -and $nodeEntry)
    if (-not $hasInstall) {
        Write-Warn "Claude Code does not appear to be installed."
        Write-Info "Nothing to remove."
        exit 0
    }

    Write-Step "Detected installation"
    if ($isWinget)         { Write-Info "winget:   Claude Code (Anthropic.ClaudeCode)" }
    if ($isNpmInstall)     { Write-Info "npm:      @anthropic-ai/claude-code (global, $npmBin)" }
    if ($installedVersion) { Write-Info "Version:  v$installedVersion" }
    foreach ($exe in $foundExes) { Write-Info "Binary:   $exe" }
    if (Test-Path $DOWNLOAD_CACHE) { Write-Info "Cache:    $DOWNLOAD_CACHE" }
    if ($ccEntry)  { Write-Info "CC Switch: $($ccEntry.DisplayName) v$($ccEntry.DisplayVersion)" }
    if ($gitEntry) {
        $gitLabel = if ($installerManagedGit) { "installed by this installer" } else { "kept (not installer-managed)" }
        Write-Info "Git:       $($gitEntry.DisplayName) [$gitLabel]"
    }
    if ($nodeEntry) {
        $nodeLabel = if ($installerManagedNode) { "installed by this installer" } else { "kept (not installer-managed)" }
        Write-Info "Node.js:   $($nodeEntry.DisplayName) [$nodeLabel]"
    }
    if ($anthropicKeys) { Write-Info "ANTHROPIC_*: $($anthropicKeys -join ', ') (user env)" }
    Write-Host ""

    # Collect choices
    $removeWinget      = $false
    $removeNpm         = $false
    $removeBinaries    = @()
    $removeDirs        = @()
    $removePathDirs    = @()
    $removeCache       = $false
    $removeConfig      = $false
    $removeCcSwitch    = $false
    $removeAnthropicEnv = $false
    $removeGit         = $false
    $removeNode        = $false

    if ($isWinget) {
        $removeWinget = Ask-YesNo "Remove Claude Code (winget)?"
    }

    if ($isNpmInstall) {
        $removeNpm = Ask-YesNo "Uninstall Claude Code (npm global, @anthropic-ai/claude-code)?"
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
    if ($gitEntry -and $installerManagedGit) {
        $removeGit = Ask-YesNo "Remove Git for Windows installed by this installer ($($gitEntry.DisplayName))?" $true
    }
    if ($nodeEntry -and $installerManagedNode) {
        $removeNode = Ask-YesNo "Remove Node.js installed by this installer ($($nodeEntry.DisplayName))?" $true
    }

    # Check anything selected
    $anySelected = $removeWinget -or $removeNpm -or ($removeBinaries.Count -gt 0) -or $removeCache -or $removeConfig `
                   -or $removeCcSwitch -or $removeAnthropicEnv -or $removeGit -or $removeNode
    if (-not $anySelected) {
        Write-Host "`nNothing selected. Exiting."
        exit 0
    }

    # Summary
    Write-Host ""
    Write-Host "The following will be removed:" -ForegroundColor Yellow
    if ($removeWinget)                 { Write-Host "  - Claude Code (winget)" }
    if ($removeNpm)                    { Write-Host "  - Claude Code (npm global, @anthropic-ai/claude-code)" }
    foreach ($exe in $removeBinaries)  { Write-Host "  - Binary:    $exe" }
    foreach ($dir in $removeDirs)      { Write-Host "  - Directory: $dir" }
    foreach ($dir in $removePathDirs)  { Write-Host "  - PATH entry: $dir" }
    if ($removeCache)       { Write-Host "  - Cache:     $DOWNLOAD_CACHE" }
    if ($removeConfig)      { Write-Host "  - Config:    $CLAUDE_CONFIG_DIR  +  $CLAUDE_CONFIG_FILE" }
    if ($removeCcSwitch)    { Write-Host "  - CC Switch" }
    if ($removeAnthropicEnv) { Write-Host "  - ANTHROPIC_* user environment variables" }
    if ($removeGit)         { Write-Host "  - Git for Windows ($($gitEntry.DisplayName))" }
    if ($removeNode)        { Write-Host "  - Node.js ($($nodeEntry.DisplayName))" }
    Write-Host ""

    if (-not (Ask-YesNo "Proceed?")) {
        Write-Host "`nCancelled."
        exit 0
    }

    Write-Step "Removing..."

    if ($removeWinget) { Uninstall-ViaWinget -WingetExe $wingetExe }

    if ($removeNpm) {
        $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
        if ($npmCmd) {
            Write-Info "Running: npm uninstall -g @anthropic-ai/claude-code"
            try {
                & $npmCmd.Source uninstall -g "@anthropic-ai/claude-code" 2>&1 | ForEach-Object { Write-Info "  $_" }
                Write-Ok "npm: @anthropic-ai/claude-code uninstalled."
            } catch {
                Write-Warn "npm uninstall failed: $($_.Exception.Message)"
            }
        } else {
            Write-Warn "npm not found. Uninstall manually: npm uninstall -g @anthropic-ai/claude-code"
        }
        # Restore claude.ps1 shim if we previously disabled it
        $disabledShim = "$npmBin\claude.ps1.disabled"
        $shimPs1      = "$npmBin\claude.ps1"
        if ((Test-Path $disabledShim) -and -not (Test-Path $shimPs1)) {
            Rename-Item $disabledShim $shimPs1 -ErrorAction SilentlyContinue
            Write-Info "Restored $npmBin\claude.ps1"
        }
        # Remove npm bin from user PATH if it was added by our installer
        $upNow = [Environment]::GetEnvironmentVariable("Path", "User")
        if ((Test-Path $NPM_PATH_MARKER) -and $null -ne $upNow -and $upNow.Contains($npmBin)) {
            Remove-FromUserPath $npmBin
            Remove-Item $NPM_PATH_MARKER -Force -ErrorAction SilentlyContinue
        } elseif ($null -ne $upNow -and $upNow.Contains($npmBin)) {
            Write-Info "Skipping PATH cleanup for $npmBin (no installer marker found)."
        }
    }

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

    if ($removeNode -and $nodeEntry) {
        Uninstall-Node -NodeEntry $nodeEntry
    }

    Write-Host ""
    Write-Host "  Uninstall complete." -ForegroundColor Green
    Write-Host ""
}

Main
