<#
.SYNOPSIS
    Claude Code Windows Installer -- ProjectAILeap
.DESCRIPTION
    Installs or upgrades Claude Code on Windows using official binaries from
    github.com/ProjectAILeap/claude-code-releases (no npm required).
    Supports GitHub mirror acceleration for users in China.
    Automatically installs Git for Windows if missing.
.NOTES
    Source:   https://github.com/ProjectAILeap/claude-code-installer
    Binaries: https://github.com/ProjectAILeap/claude-code-releases
    Official: https://claude.ai/install.ps1
#>

# Default parameters (iex context does not support param() blocks)
if (-not (Get-Variable 'NoVerify' -ErrorAction SilentlyContinue)) { $NoVerify = $false }

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference    = 'SilentlyContinue'   # speeds up Invoke-WebRequest (aligns with official)

# -- Constants -----------------------------------------------------------------
$RELEASES_REPO    = "ProjectAILeap/claude-code-releases"
$GIT_REPO         = "git-for-windows/git"
$CC_SWITCH_REPO   = "farion1231/cc-switch"
$DOWNLOAD_DIR     = "$env:USERPROFILE\.claude\downloads"   # aligns with official
$CLAUDE_JSON      = "$env:USERPROFILE\.claude.json"
$GIT_MIN_VER      = [Version]"2.40.0"
$GIT_FALLBACK_VER = "2.47.1"
$GIT_FALLBACK_TAG = "v2.47.1.windows.1"

$MIRRORS = @(
    "https://github.com",
    "https://ghfast.top/https://github.com",
    "https://gh-proxy.com/https://github.com",
    "https://mirror.ghproxy.com/https://github.com",
    "https://kkgithub.com"
)

# -- Output --------------------------------------------------------------------
function Write-Step { param($msg) Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-Info { param($msg) Write-Host "  [INFO]  $msg" -ForegroundColor Gray }
function Write-Ok   { param($msg) Write-Host "  [ OK ]  $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "  [WARN]  $msg" -ForegroundColor Yellow }
function Write-Err  { param($msg) Write-Host "  [ERR ]  $msg" -ForegroundColor Red }

function Exit-WithError {
    param($msg)
    Write-Err $msg
    exit 1
}

# -- Mirror selection ----------------------------------------------------------
$global:SelectedMirror = ""

function Get-MirrorTestUrl {
    param([string]$Mirror)
    if ($Mirror -match '/https://github\.com$') {
        return ($Mirror -replace '/https://github\.com$', '/https://raw.githubusercontent.com') + `
               "/ProjectAILeap/claude-code-installer/main/README.md"
    }
    return "$Mirror/$RELEASES_REPO/releases"
}

function Select-Mirror {
    Write-Step "Testing mirror speeds..."

    $jobs = @()
    foreach ($m in $MIRRORS) {
        $url = Get-MirrorTestUrl $m
        $jobs += Start-Job -ScriptBlock {
            param($mirror, $u)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $r = Invoke-WebRequest -Uri $u -Method Head -TimeoutSec 6 -UseBasicParsing -ErrorAction Stop
                $sw.Stop()
                [PSCustomObject]@{ Mirror = $mirror; Ms = $sw.ElapsedMilliseconds; Ok = ($r.StatusCode -lt 400) }
            } catch {
                $sw.Stop()
                $ok = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ -lt 400 } else { $false }
                [PSCustomObject]@{ Mirror = $mirror; Ms = 99999; Ok = $ok }
            }
        } -ArgumentList $m, $url
    }

    $jobs | Wait-Job -Timeout 10 | Out-Null
    $allResults = @($jobs | ForEach-Object {
        if ($_.State -eq 'Completed') { Receive-Job $_ -ErrorAction SilentlyContinue }
        else { [PSCustomObject]@{ Mirror = ""; Ms = 99999; Ok = $false } }
    } | Where-Object { $_ -and $_.Mirror } | Sort-Object @{Expression='Ok';Descending=$true}, Ms)
    $jobs | Remove-Job -Force -ErrorAction SilentlyContinue

    $reachable = @($allResults | Where-Object { $_.Ok })

    foreach ($r in $allResults) {
        $t = $r.Mirror -replace 'https://([^/]+)(/.*)?$','$1'
        if ($r.Ok) {
            Write-Info ("  {0,-30} {1,6} ms" -f $t, $r.Ms)
        } else {
            Write-Info ("  {0,-30} timeout" -f $t)
        }
    }
    Write-Host ""

    if ($reachable.Count -gt 0) {
        $best = $reachable[0]
        $global:SelectedMirror = $best.Mirror
        $tag = $best.Mirror -replace 'https://([^/]+)(/.*)?$','$1'
        Write-Ok "Selected: $tag ($($best.Ms) ms)"
    } else {
        $global:SelectedMirror = "https://ghfast.top/https://github.com"
        Write-Warn "All mirror checks timed out. Defaulting to ghfast.top."
    }
}

function Get-DownloadUrl {
    param([string]$Path)
    return "$global:SelectedMirror$Path"
}

# -- Fetch latest version ------------------------------------------------------
function Get-LatestVersion {
    Write-Step "Fetching latest Claude Code version..."
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
        try {
            $fallbackUrl = "https://kkgithub.com/$RELEASES_REPO/releases/latest"
            $resp = Invoke-WebRequest -Uri $fallbackUrl -Method Head `
                -TimeoutSec 10 -UseBasicParsing -MaximumRedirection 0 `
                -ErrorAction SilentlyContinue
            $locationHdr = $resp.Headers["Location"]
            $location = if ($null -ne $locationHdr) { $locationHdr } else { "" }
            if ($location -match '(\d+\.\d+\.\d+)') { $ver = $Matches[1] }
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
    Write-Info "Latest: v$ver"
    return $ver
}

# -- Detect installed version via claude --version (aligns with official) ------
function Get-InstalledVersion {
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($cmd) {
        try {
            $out = & $cmd.Source --version 2>&1
            if ("$out" -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
        } catch {}
    }
    return ""
}

# -- Download helper -----------------------------------------------------------
function Invoke-Download {
    param(
        [string]$Url,
        [string]$OutFile,
        [string]$Label = "file",
        [int]$RetryCount = 3,
        [int]$TimeoutSec = 120
    )

    for ($i = 1; $i -le $RetryCount; $i++) {
        Write-Info "Downloading $Label (attempt $i/$RetryCount)..."
        Write-Info "  URL: $Url"
        Remove-Item $OutFile -Force -ErrorAction SilentlyContinue

        # Use Start-Job so Wait-Job -Timeout provides a true hard timeout.
        # -TimeoutSec on Invoke-WebRequest only applies to connect/headers in PS 5.1;
        # it does not abort a stalled mid-transfer.
        $job = Start-Job -ScriptBlock {
            param($u, $out)
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $u -OutFile $out -UseBasicParsing -ErrorAction Stop
        } -ArgumentList $Url, $OutFile

        $finished = Wait-Job $job -Timeout $TimeoutSec

        if ($finished -and $job.State -eq 'Completed') {
            Receive-Job $job -ErrorAction SilentlyContinue | Out-Null
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            if (Test-Path $OutFile) {
                Unblock-File -Path $OutFile -ErrorAction SilentlyContinue
                $sizeMB = [math]::Round((Get-Item $OutFile).Length / 1MB, 1)
                Write-Ok "Downloaded $Label ($sizeMB MB)"
                return $true
            }
            Write-Warn "  Attempt $i: job completed but output file missing."
        } else {
            $errMsg = ""
            if ($job.State -eq 'Failed') {
                $errMsg = "$( (Receive-Job $job -ErrorAction SilentlyContinue 2>&1) )"
            }
            Stop-Job  $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
            if ($errMsg) {
                Write-Warn "  Attempt $i failed: $errMsg"
            } else {
                Write-Warn "  Attempt $i timed out after ${TimeoutSec}s."
            }
        }
        if ($i -lt $RetryCount) { Start-Sleep -Seconds 2 }
    }
    return $false
}

# -- Multi-mirror download -----------------------------------------------------
function Invoke-DownloadMirror {
    param(
        [string]$Path,
        [string]$OutFile,
        [string]$Label = "file"
    )
    $order = @($global:SelectedMirror) + ($MIRRORS | Where-Object { $_ -ne $global:SelectedMirror })
    $seen  = @()
    foreach ($m in $order) {
        $url = "$m$Path"
        if ($seen -contains $url) { continue }
        $seen += $url
        if (Invoke-Download -Url $url -OutFile $OutFile -Label $Label -RetryCount 1) {
            return $true
        }
        Write-Info "  Trying next mirror..."
    }
    return $false
}

# -- SHA-256 verification ------------------------------------------------------
function Test-Checksum {
    param(
        [string]$FilePath,
        [string]$ChecksumFile,
        [string]$FileName
    )

    $content  = Get-Content $ChecksumFile -Raw
    $expected = ""

    foreach ($line in ($content -split "`n")) {
        $line = $line.Trim()
        if ($line -match "^([a-f0-9]{64})\s+\*?$FileName") {
            $expected = $Matches[1]; break
        }
    }

    if (-not $expected) {
        Write-Warn "No checksum entry for $FileName, skipping verification."
        return $true
    }

    $actual = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash.ToLower()
    if ($actual -eq $expected.ToLower()) {
        Write-Ok "SHA-256 verified."; return $true
    } else {
        Write-Err "Checksum mismatch!  Expected: $expected  Got: $actual"
        return $false
    }
}

# -- Ensure Git for Windows ----------------------------------------------------
function Ensure-Git {
    Write-Step "Checking Git for Windows..."

    $gitExe = $null
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) { $gitExe = $gitCmd.Source }
    if (-not $gitExe) {
        foreach ($p in @(
            "C:\Program Files\Git\cmd\git.exe",
            "C:\Program Files\Git\bin\git.exe"
        )) {
            if (Test-Path $p) { $gitExe = $p; break }
        }
    }

    $needInstall = $true
    if ($gitExe) {
        try {
            $out = & $gitExe --version 2>&1
            if ("$out" -match 'git version (\d+\.\d+\.\d+)') {
                $ver = [Version]$Matches[1]
                if ($ver -ge $GIT_MIN_VER) {
                    Write-Ok "Git $($Matches[1]) -- OK"
                    $needInstall = $false
                } else {
                    Write-Info "Git $($Matches[1]) < $GIT_MIN_VER, upgrading..."
                }
            }
        } catch {}
    } else {
        Write-Info "Git not found."
    }

    if (-not $needInstall) { return }

    Write-Info "Installing Git for Windows..."

    $gitVer = $GIT_FALLBACK_VER
    $gitTag = $GIT_FALLBACK_TAG

    try {
        $list = Invoke-RestMethod `
            -Uri "https://registry.npmmirror.com/-/binary/git-for-windows/" `
            -TimeoutSec 8 -ErrorAction Stop
        $last = $list |
            Where-Object { $_.name -match '^v\d+\.\d+\.\d+\.windows\.\d+/$' } |
            Select-Object -Last 1
        if ($last) {
            $gitTag = $last.name.TrimEnd('/')
            $gitVer = if ($gitTag -match '^v(\d+\.\d+\.\d+)\.windows\.([2-9]\d*)$') {
                "$($Matches[1]).$($Matches[2])"
            } else { $gitTag -replace '^v(\d+\.\d+\.\d+).*', '$1' }
            Write-Info "  Version (npmmirror): $gitTag"
        }
    } catch {
        Write-Info "  npmmirror unavailable, trying GitHub API..."
        try {
            $rel = Invoke-RestMethod `
                -Uri "https://api.github.com/repos/$GIT_REPO/releases/latest" `
                -TimeoutSec 8 -ErrorAction Stop
            $gitTag = $rel.tag_name
            $gitVer = if ($gitTag -match '^v(\d+\.\d+\.\d+)\.windows\.([2-9]\d*)$') {
                "$($Matches[1]).$($Matches[2])"
            } else { $gitTag -replace '^v(\d+\.\d+\.\d+).*', '$1' }
            Write-Info "  Version (GitHub): $gitTag"
        } catch {
            Write-Info "  Using fallback: $gitTag"
        }
    }

    $exeName = "Git-$gitVer-64-bit.exe"
    $tmpExe  = "$env:TEMP\$exeName"

    $gitUrls = @(
        "https://npmmirror.com/mirrors/git-for-windows/$gitTag/$exeName",
        (Get-DownloadUrl "/$GIT_REPO/releases/download/$gitTag/$exeName"),
        "https://github.com/$GIT_REPO/releases/download/$gitTag/$exeName"
    ) | Select-Object -Unique

    $downloaded = $false
    if (Test-Path $tmpExe) {
        Write-Info "  Installer already cached: $exeName"
        $downloaded = $true
    } else {
        foreach ($url in $gitUrls) {
            if (Invoke-Download -Url $url -OutFile $tmpExe -Label "Git $gitVer") {
                $downloaded = $true; break
            }
        }
    }

    if ($downloaded) {
        Write-Info "  Installing Git silently..."
        try {
            $proc = Start-Process -FilePath $tmpExe `
                -ArgumentList '/VERYSILENT /NORESTART /NOCANCEL /SP- /CLOSEAPPLICATIONS /CURRENTUSER /COMPONENTS="icons,ext\reg\shellhere,assoc,assoc_sh"' `
                -Wait -PassThru -ErrorAction Stop
            if ($proc.ExitCode -eq 0) {
                Write-Ok "Git installed."
            } else {
                Write-Warn "Git installer exited with code $($proc.ExitCode)."
            }
        } catch {
            Write-Warn "Failed to run Git installer: $($_.Exception.Message)"
        }
        Remove-Item $tmpExe -Force -ErrorAction SilentlyContinue
    } else {
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget) {
            Write-Info "  Trying winget..."
            try {
                & winget install -e --id Git.Git --source winget `
                    --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
                Write-Ok "Git installed via winget."
                $downloaded = $true
            } catch {
                Write-Warn "winget install failed: $($_.Exception.Message)"
            }
        }
        if (-not $downloaded) {
            Write-Warn "Could not install Git automatically."
            Write-Info "Download manually: https://git-scm.com/download/win"
            Write-Warn "Some Claude Code features may not work without Git."
            return
        }
    }

    # Refresh PATH so git is available in current session
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine"); if ($null -eq $machine) { $machine = "" }
    $user    = [Environment]::GetEnvironmentVariable("Path", "User");    if ($null -eq $user)    { $user    = "" }
    $env:Path = "$machine;$user"
}

# -- Write ~/.claude.json ------------------------------------------------------
function Write-ClaudeJson {
    try {
        if (Test-Path $CLAUDE_JSON) {
            $obj = Get-Content $CLAUDE_JSON -Raw | ConvertFrom-Json -ErrorAction Stop
            $obj | Add-Member -NotePropertyName "hasCompletedOnboarding" `
                              -NotePropertyValue $true -Force
            $obj | ConvertTo-Json -Depth 10 |
                Set-Content -Path $CLAUDE_JSON -Encoding UTF8
        } else {
            '{"hasCompletedOnboarding": true}' |
                Set-Content -Path $CLAUDE_JSON -Encoding UTF8
        }
        Write-Info "~/.claude.json: onboarding skip set."
    } catch {
        Write-Warn "Could not write ~/.claude.json: $($_.Exception.Message)"
    }
}

# -- Configure API / Provider --------------------------------------------------
function Configure-ApiKey {
    param([bool]$CcSwitchInstalled)

    Write-Step "Configuring API access..."

    $existingKey = [Environment]::GetEnvironmentVariable("ANTHROPIC_API_KEY", "User")
    if ($existingKey -and $existingKey -ne "PLACEHOLDER_USE_CC_SWITCH") {
        Write-Ok "ANTHROPIC_API_KEY already configured."
        Write-ClaudeJson
        return
    }

    $canReach = $false
    try {
        Invoke-WebRequest -Uri "https://api.anthropic.com" -Method Head `
            -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop | Out-Null
        $canReach = $true
    } catch {
        if ($_.Exception.Response -ne $null) { $canReach = $true }
    }

    if ($CcSwitchInstalled) {
        Write-Info "CC Switch installed -> setting placeholder provider config..."
        [Environment]::SetEnvironmentVariable("ANTHROPIC_BASE_URL", "https://api.deepseek.com", "User")
        [Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY",  "PLACEHOLDER_USE_CC_SWITCH", "User")
        $env:ANTHROPIC_BASE_URL = "https://api.deepseek.com"
        $env:ANTHROPIC_API_KEY  = "PLACEHOLDER_USE_CC_SWITCH"
        Write-Ok "Placeholder set. Open CC Switch to configure your Provider and API Key."

    } elseif ($canReach) {
        Write-Info "Anthropic API is reachable directly."
        Write-Host ""
        Write-Host "  Enter your Anthropic API Key (sk-ant-...), or press Enter to skip:" `
            -ForegroundColor Yellow
        $apiKey = Read-Host "  API Key"
        if ($apiKey -and $apiKey.Trim() -ne "") {
            [Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY", $apiKey.Trim(), "User")
            $env:ANTHROPIC_API_KEY = $apiKey.Trim()
            Write-Ok "API Key saved to user environment."
        } else {
            Write-Warn "Skipped. Claude Code will prompt for API Key on first launch."
        }

    } else {
        Write-Warn "Cannot reach api.anthropic.com directly."
        Write-Host ""
        Write-Host "  Recommended options:" -ForegroundColor Yellow
        Write-Host "   1. Re-run installer and install CC Switch"
        Write-Host "      -> Use DeepSeek / Kimi / GLM / Aliyun as provider (no VPN needed)"
        Write-Host "   2. Set up a proxy, then re-run installer"
        Write-Host "   3. Set manually after install:"
        Write-Host "        `$env:ANTHROPIC_BASE_URL = 'https://api.your-provider.com'"
        Write-Host "        `$env:ANTHROPIC_API_KEY  = 'your-api-key'"
        Write-Host ""
    }

    Write-ClaudeJson
}

# -- Optional: CC Switch -------------------------------------------------------
function Install-CcSwitch {
    Write-Step "Installing CC Switch (optional)..."

    $ccVer = ""
    try {
        $ccApi = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$CC_SWITCH_REPO/releases/latest" `
            -TimeoutSec 10 -ErrorAction Stop
        $ccVer = $ccApi.tag_name -replace '^v', ''
    } catch {
        Write-Warn "Could not fetch CC Switch version."
    }

    if (-not $ccVer) {
        Write-Info "Download manually: https://github.com/$CC_SWITCH_REPO/releases"
        return $false
    }

    $msiName = "CC-Switch-v$ccVer-Windows.msi"
    $msiPath = "$env:TEMP\$msiName"

    $msiUrls = @(
        (Get-DownloadUrl "/$CC_SWITCH_REPO/releases/download/v$ccVer/$msiName"),
        "https://ghfast.top/https://github.com/$CC_SWITCH_REPO/releases/download/v$ccVer/$msiName",
        "https://kkgithub.com/$CC_SWITCH_REPO/releases/download/v$ccVer/$msiName",
        "https://github.com/$CC_SWITCH_REPO/releases/download/v$ccVer/$msiName"
    ) | Select-Object -Unique

    $downloaded = $false
    foreach ($url in $msiUrls) {
        if (Invoke-Download -Url $url -OutFile $msiPath -Label "CC Switch $ccVer MSI") {
            $downloaded = $true; break
        }
    }

    if (-not $downloaded) {
        Write-Warn "CC Switch download failed."
        Write-Info "Download manually: https://github.com/$CC_SWITCH_REPO/releases"
        return $false
    }

    Write-Info "Installing CC Switch silently..."
    try {
        $proc = Start-Process -FilePath "msiexec.exe" `
            -ArgumentList "/i `"$msiPath`" /qn /norestart" `
            -Wait -PassThru -ErrorAction Stop
        if ($proc.ExitCode -eq 0) {
            Write-Ok "CC Switch v$ccVer installed."
            return $true
        } else {
            Write-Warn "CC Switch MSI exited with code $($proc.ExitCode)."
            Write-Info "Try running the MSI manually: $msiPath"
            return $false
        }
    } catch {
        Write-Warn "Failed to run MSI: $($_.Exception.Message)"
        Write-Info "MSI saved to: $msiPath"
        return $false
    }
}

# -- Main ----------------------------------------------------------------------
function Main {
    Write-Host ""
    Write-Host "=== Claude Code Windows Installer ===  ProjectAILeap" -ForegroundColor Cyan
    Write-Host "Source: github.com/ProjectAILeap/claude-code-releases" -ForegroundColor Gray
    Write-Host ""

    # 1. 32-bit check (aligns with official)
    if (-not [Environment]::Is64BitProcess) {
        Exit-WithError "Claude Code does not support 32-bit Windows. Please use a 64-bit version of Windows."
    }

    # 2. Platform (aligns with official: supports win32-arm64)
    $platform = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "win32-arm64" } else { "win32-x64" }

    # 3. Resolve target version
    $targetVersion = Get-LatestVersion

    # 4. Check installed version via claude --version (aligns with official)
    $installedVersion = Get-InstalledVersion
    if ($installedVersion -eq $targetVersion) {
        Write-Ok "Claude Code v$targetVersion is already up to date."
        exit 0
    }
    if ($installedVersion) {
        Write-Info "Upgrading: v$installedVersion -> v$targetVersion"
    } else {
        Write-Info "Installing Claude Code v$targetVersion"
    }

    # 5. Select fastest mirror
    Select-Mirror

    # 6. Ensure Git
    Ensure-Git

    # 7. Prepare download dir (aligns with official: ~/.claude/downloads)
    New-Item -ItemType Directory -Force -Path $DOWNLOAD_DIR | Out-Null

    $fileName  = "claude-$targetVersion-$platform.exe"
    $dlPath    = "/$RELEASES_REPO/releases/download/v$targetVersion/$fileName"
    $ckPath    = "/$RELEASES_REPO/releases/download/v$targetVersion/sha256sums.txt"
    $binaryPath = "$DOWNLOAD_DIR\$fileName"
    $ckFile    = "$DOWNLOAD_DIR\sha256sums-$targetVersion.txt"

    # 8. Download checksums (for cache verification)
    $ckOk = $false
    if (Test-Path $ckFile) {
        $ckOk = $true
    } else {
        $ckOk = Invoke-DownloadMirror -Path $ckPath -OutFile $ckFile -Label "checksums"
    }

    # 9. Download binary (with cache)
    $needDownload = $true
    if (Test-Path $binaryPath) {
        if ($ckOk) {
            if (Test-Checksum -FilePath $binaryPath -ChecksumFile $ckFile -FileName $fileName) {
                Write-Step "Using cached $fileName (checksum OK)..."
                $needDownload = $false
            } else {
                Write-Warn "Cached file checksum mismatch, re-downloading..."
                Remove-Item $binaryPath -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-Step "Using cached $fileName (checksum unavailable)..."
            $needDownload = $false
        }
    }

    if ($needDownload) {
        Write-Step "Downloading $fileName..."
        Write-Info "Binary size is ~45 MB, no progress bar -- please wait..."
        if (-not (Invoke-DownloadMirror -Path $dlPath -OutFile $binaryPath -Label "Claude Code binary")) {
            Exit-WithError "Download failed. Try a different mirror or check your connection."
        }
        if ($needDownload -and -not $NoVerify -and $ckOk) {
            if (-not (Test-Checksum -FilePath $binaryPath -ChecksumFile $ckFile -FileName $fileName)) {
                Remove-Item $binaryPath -Force -ErrorAction SilentlyContinue
                Exit-WithError "Checksum verification failed. The file may be corrupted."
            }
        }
    }

    # 10. Run install (aligns with official: let the binary handle setup)
    Write-Step "Setting up Claude Code..."
    try {
        & $binaryPath install
    } catch {
        Exit-WithError "Installation failed: $($_.Exception.Message)"
    }

    # 12. Optional: CC Switch
    Write-Host ""
    $installCcSwitch = Read-Host "Install CC Switch (API Provider switcher)? [y/N]"
    $ccSwitchInstalled = $false
    if ($installCcSwitch -match '^[Yy]') {
        $ccSwitchInstalled = Install-CcSwitch
    }

    # 13. API / Provider configuration
    Configure-ApiKey -CcSwitchInstalled $ccSwitchInstalled

    # 14. Done
    Write-Host ""
    Write-Output "[OK] Installation complete!"
    Write-Host ""
    Write-Host "  Quick start:"
    Write-Host "    claude            -- start Claude Code"
    Write-Host "    claude --version  -- verify installation"
    Write-Host ""
    if ($ccSwitchInstalled) {
        Write-Host "  CC Switch: open from Start Menu to configure your API Provider." -ForegroundColor Cyan
        Write-Host ""
    }
    Write-Host "  To upgrade: re-run install.bat"
    Write-Host "  To uninstall: run uninstall.bat"
    Write-Host ""
}

Main
