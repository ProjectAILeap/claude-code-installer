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

# ── Self-elevation ────────────────────────────────────────────────────────────
# Request admin rights once at startup so Git/Node installs run silently.
if (($env:OS -eq 'Windows_NT') -and
    -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $pwsh = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh.exe" } else { "powershell.exe" }
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) {
        # irm | iex context: materialise the script to a temp file then re-launch
        $scriptPath = "$env:TEMP\claude-code-installer-elevated.ps1"
        $MyInvocation.MyCommand.ScriptBlock.ToString() | Set-Content $scriptPath -Encoding UTF8
    }
    Start-Process $pwsh -Verb RunAs `
        -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$scriptPath`"" -Wait
    exit
}

# Default parameters (iex context does not support param() blocks)
if (-not (Get-Variable 'NoVerify'   -ErrorAction SilentlyContinue)) { $NoVerify   = $false }
if (-not $env:CLAUDE_INSTALL_TIMEOUT) { $env:CLAUDE_INSTALL_TIMEOUT = "25" }
if (-not $env:CLAUDE_INSTALL_MODE)    { $env:CLAUDE_INSTALL_MODE    = "auto" }

Set-StrictMode -Version Latest
$ErrorActionPreference    = "Stop"
$ProgressPreference       = 'SilentlyContinue'   # speeds up Invoke-WebRequest (aligns with official)
$OutputEncoding           = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# -- Constants -----------------------------------------------------------------
$RELEASES_REPO    = "ProjectAILeap/claude-code-releases"
$GIT_REPO         = "git-for-windows/git"
$CC_SWITCH_REPO   = "farion1231/cc-switch"
$DOWNLOAD_DIR     = "$env:USERPROFILE\.claude\downloads"   # aligns with official
$CLAUDE_JSON      = "$env:USERPROFILE\.claude.json"
$NPM_PATH_MARKER  = "$env:USERPROFILE\.claude\npm-path-added"
$GIT_INSTALL_MARKER = "$env:USERPROFILE\.claude\git-installed-by-installer"
$NODE_INSTALL_MARKER = "$env:USERPROFILE\.claude\node-installed-by-installer"
$GIT_MIN_VER      = [Version]"2.40.0"
$GIT_FALLBACK_VER = "2.47.1"
$GIT_FALLBACK_TAG = "v2.47.1.windows.1"

$GCS_BUCKET = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"

$MIRRORS = @(
    "https://github.com",
    "https://ghfast.top/https://github.com",
    "https://gh-proxy.com/https://github.com",
    "https://mirror.ghproxy.com/https://github.com",
    "https://ghproxy.net/https://github.com",
    "https://hub.gitmirror.com/https://github.com"
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

function Write-InstallerMarker {
    param(
        [string]$Path,
        [string]$Signature
    )
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
        if ($Signature) {
            Set-Content -Path $Path -Value $Signature -Encoding UTF8 -Force
        } else {
            Set-Content -Path $Path -Value "installed-by-claude-code-installer" -Encoding ASCII -Force
        }
    } catch {
        Write-Warn "Could not write installer marker: $Path"
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

function Find-RegistryEntryByPatterns {
    param([string[]]$Patterns)
    $paths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    return Get-ItemProperty $paths -ErrorAction SilentlyContinue |
        Where-Object {
            $entry = $_
            if (-not $entry.PSObject.Properties['DisplayName']) { return $false }
            foreach ($pattern in $Patterns) {
                if ($entry.DisplayName -like $pattern) { return $true }
            }
            return $false
        } |
        Select-Object -First 1
}

function Find-GitInstallEntry {
    return Find-RegistryEntryByPatterns @("Git version *", "Git", "Git for Windows*")
}

function Find-NodeInstallEntry {
    return Find-RegistryEntryByPatterns @("Node.js*", "Node.js LTS*")
}

# -- Mirror selection ----------------------------------------------------------
$global:SelectedMirror     = ""
$global:GithubMirror       = ""   # fastest mirror (used for CC Switch / Git)
$global:IsGCS             = $false
$global:InstalledViaWinget = $false
$global:InstalledViaNpm    = $false
$global:InstallMethod      = ""
$global:InstalledClaudeExe = ""

function Test-AnthropicApiReachable {
    try {
        Invoke-WebRequest -Uri "https://api.anthropic.com" -Method Head `
            -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return ($_.Exception.Response -ne $null)
    }
}

function Select-Mirror {
    param([string]$Version)

    # GCS (storage.googleapis.com) is excluded: responds fast to probes but
    # binary downloads time out for China users (blocked by GFW).
    Write-Step "Testing mirror speeds (GitHub mirrors)..."

    # Use HttpClient async tasks (in-process, no Start-Job overhead).
    # ResponseHeadersRead = stop as soon as headers arrive, don't download body.
    Add-Type -AssemblyName System.Net.Http   # required on PS 5.1 / .NET Framework
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $true
    $client  = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [System.TimeSpan]::FromSeconds(20)

    $allSources = $MIRRORS
    $tasks = [ordered]@{}
    $sw    = [ordered]@{}

    foreach ($m in $allSources) {
        $url = "$m/$RELEASES_REPO/releases/download/v$Version/sha256sums.txt"
        $cts = [System.Threading.CancellationTokenSource]::new(15000)  # 15s per mirror
        $sw[$m]    = [System.Diagnostics.Stopwatch]::StartNew()
        $tasks[$m] = $client.GetAsync($url,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $cts.Token)
    }

    # Collect results: wait up to 18s total for all tasks
    $deadline = [System.DateTime]::UtcNow.AddSeconds(18)
    $rawResults = foreach ($m in $tasks.Keys) {
        $task = $tasks[$m]
        $remaining = [int][math]::Max(0, ($deadline - [System.DateTime]::UtcNow).TotalMilliseconds)
        # .Wait() throws AggregateException when task is cancelled or faulted
        $completed = $false
        try { $completed = $task.Wait($remaining) } catch {}
        $sw[$m].Stop()
        $ms = $sw[$m].ElapsedMilliseconds
        $ok = $false
        if ($completed -and $task.Status -eq 'RanToCompletion') {
            try {
                $ok = $task.Result.IsSuccessStatusCode -or [int]$task.Result.StatusCode -lt 500
                $task.Result.Dispose()
            } catch {}
        }
        [PSCustomObject]@{ Mirror = $m; Ms = $ms; Ok = $ok }
    }
    $client.Dispose()
    $allResults = @($rawResults | Sort-Object @{Expression='Ok';Descending=$true}, Ms)

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
        $global:GithubMirror   = $best.Mirror
        $global:IsGCS          = $false
        $tag = $best.Mirror -replace 'https://([^/]+)(/.*)?$','$1'
        Write-Ok "Selected: $tag ($($best.Ms) ms)"
    } else {
        $global:SelectedMirror = "https://ghfast.top/https://github.com"
        $global:GithubMirror   = "https://ghfast.top/https://github.com"
        $global:IsGCS          = $false
        Write-Warn "All mirror checks timed out. Defaulting to ghfast.top."
    }
}

function Get-DownloadUrl {
    param([string]$Path)
    # Always use a GitHub mirror (GCS does not host CC Switch / Git releases)
    $mirror = if ($global:GithubMirror) { $global:GithubMirror } else { "https://github.com" }
    return "$mirror$Path"
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
            $fallbackUrl = "https://github.com/$RELEASES_REPO/releases/latest"
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
    $LOCAL_EXE = "$env:USERPROFILE\.local\bin\claude.exe"
    $exe = $null
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($cmd) { $exe = $cmd.Source }
    elseif (Test-Path $LOCAL_EXE) { $exe = $LOCAL_EXE }
    if ($exe) {
        try {
            $out = & $exe --version 2>&1
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
            $ProgressPreference       = 'SilentlyContinue'
            $OutputEncoding           = [System.Text.Encoding]::UTF8
            [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
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
            Write-Warn "  Attempt ${i}: job completed but output file missing."
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
    # Use GitHub mirrors only (GCS has a different URL structure and is not used here)
    $primary = if ($global:GithubMirror) { $global:GithubMirror } else { "https://github.com" }
    $order = @($primary) + ($MIRRORS | Where-Object { $_ -ne $primary })
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

# -- SHA-256 verification via manifest.json ------------------------------------
function Test-Checksum {
    param(
        [string]$FilePath,
        [string]$ManifestFile,
        [string]$Platform
    )

    $expected = ""
    try {
        $manifest = Get-Content $ManifestFile -Raw | ConvertFrom-Json -ErrorAction Stop
        $expected = $manifest.platforms.$Platform.checksum
    } catch {
        Write-Warn "Could not parse manifest.json, skipping verification."
        return $true
    }

    if (-not $expected) {
        Write-Warn "No checksum for '$Platform' in manifest, skipping verification."
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
    $gitWasMissing = $true
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

    if ($gitExe) { $gitWasMissing = $false }

    if (-not $needInstall) { return }

    Write-Info "Installing Git for Windows..."

    # Use npmmirror installer directly (fast for China users, no UAC with /CURRENTUSER for non-admin).
    # winget downloads Git from GitHub which is slow/blocked in China -- not worth the 60s wait.
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
                $gitArgs = '/VERYSILENT /NORESTART /NOCANCEL /SP- /SUPPRESSMSGBOXES /CLOSEAPPLICATIONS /COMPONENTS="icons,ext\reg\shellhere,assoc,assoc_sh"'
                $proc = Start-Process -FilePath $tmpExe -ArgumentList $gitArgs -Wait -PassThru -ErrorAction Stop
                if ($proc.ExitCode -eq 0) {
                    Write-Ok "Git installed."
                    if ($gitWasMissing) {
                        Write-InstallerMarker -Path $GIT_INSTALL_MARKER -Signature (Get-InstallEntrySignature (Find-GitInstallEntry))
                    }
                }
                else { Write-Warn "Git installer exited with code $($proc.ExitCode)." }
            } catch {
                Write-Warn "Failed to run Git installer: $($_.Exception.Message)"
            }
            Remove-Item $tmpExe -Force -ErrorAction SilentlyContinue
        } else {
            Write-Warn "Could not install Git automatically."
            Write-Info "Download manually: https://git-scm.com/download/win"
            Write-Warn "Some Claude Code features may not work without Git."
            return
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

    $canReach = Test-AnthropicApiReachable

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

# -- CC Switch already-installed detection -------------------------------------
function Test-CcSwitchInstalled {
    $paths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $entry = Get-ItemProperty $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like "*CC Switch*" } |
        Select-Object -First 1
    return $null -ne $entry
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

# -- Winget helpers ------------------------------------------------------------
function Get-WingetExe {
    # 1. Already in PATH
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # 2. Standard AppX symlink location -- %LOCALAPPDATA%\Microsoft\WindowsApps is in User PATH
    #    by default, so this path works in new terminals without any PATH modification.
    $localLink = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"
    if (Test-Path $localLink) { return $localLink }
    # 3. Fallback: find via AppxPackage InstallLocation (protected dir, full path only)
    $pkg = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($pkg) {
        $exe = Join-Path $pkg.InstallLocation "winget.exe"
        if (Test-Path $exe) { return $exe }
    }
    return $null
}

function Ensure-WingetAlias {
    param([string]$WingetExe)
    # Already accessible by name -- nothing to do
    if (Get-Command winget -ErrorAction SilentlyContinue) { return }

    # Set alias for current session immediately
    Set-Alias -Name winget -Value $WingetExe -Scope Global

    # Ensure $PROFILE is loaded in future sessions:
    # If ExecutionPolicy is Restricted, $PROFILE is never sourced -- set to RemoteSigned.
    $policy = Get-ExecutionPolicy -Scope CurrentUser -ErrorAction SilentlyContinue
    if ($policy -eq 'Restricted' -or $policy -eq 'Undefined') {
        try {
            Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
            Write-Info "ExecutionPolicy set to RemoteSigned (required to load `$PROFILE)."
        } catch {
            Write-Warn "Could not set ExecutionPolicy: $($_.Exception.Message)"
        }
    }

    # Write Set-Alias to $PROFILE.CurrentUserCurrentHost
    # Use explicit property to avoid ambiguity ($PROFILE alone may vary by host)
    $profilePath = $PROFILE.CurrentUserCurrentHost
    $profileDir  = Split-Path $profilePath -Parent
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }
    if (-not (Test-Path $profilePath)) {
        New-Item -ItemType File -Path $profilePath -Force | Out-Null
    }
    $aliasLine = "Set-Alias winget `"$WingetExe`"  # added by claude-code-installer"
    $existing  = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
    if ($existing -notlike "*Set-Alias winget*") {
        Add-Content -Path $profilePath -Value "`n$aliasLine" -Encoding UTF8
        Write-Ok "winget alias written to `$PROFILE -- new PowerShell windows will have 'winget'."
    }
}

function Install-Winget {
    Write-Step "Installing winget (Windows Package Manager)..."
    try {
        $tmp    = [System.IO.Path]::GetTempPath()
        $vclibs = Join-Path $tmp "Microsoft.VCLibs.x64.14.00.Desktop.appx"
        $appins = Join-Path $tmp "Microsoft.DesktopAppInstaller.msixbundle"

        Write-Info "Downloading VCLibs..."
        Invoke-WebRequest -Uri "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx" `
            -OutFile $vclibs -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        try { Add-AppxPackage -Path $vclibs -ErrorAction SilentlyContinue } catch {}

        Write-Info "Downloading winget package (~15 MB)..."
        Invoke-WebRequest -Uri "https://aka.ms/getwinget" `
            -OutFile $appins -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        Add-AppxPackage -Path $appins
        Start-Sleep -Seconds 3
        Write-Ok "winget installed."
        # Refresh PATH so winget is usable immediately in current session
        $wingetExeNow = Get-WingetExe
        if ($wingetExeNow) {
            $wingetDir = Split-Path $wingetExeNow
            $localWindowsApps = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps"
            if ($wingetDir -ne $localWindowsApps) {
                # Not the standard AppX symlink path -- add to User PATH and current session
                $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
                if ($null -eq $userPath) { $userPath = "" }
                if ($userPath -notlike "*$wingetDir*") {
                    [Environment]::SetEnvironmentVariable("Path", "$userPath;$wingetDir", "User")
                }
            }
            if ($env:Path -notlike "*$wingetDir*") {
                $env:Path = "$env:Path;$wingetDir"
            }
            Write-Info "winget available: $wingetExeNow"
            Ensure-WingetAlias -WingetExe $wingetExeNow
        }
    } catch {
        Write-Warn "Failed to install winget: $($_.Exception.Message)"
    }
}

# -- Optional: winget install path ---------------------------------------------
function Install-ViaWinget {
    param([string]$WingetExe = "winget")
    Write-Step "Installing Claude Code via winget (timeout 120s)..."
    try {
        $proc = Start-Process $WingetExe `
            -ArgumentList "install -e --id Anthropic.ClaudeCode --source winget --accept-source-agreements --accept-package-agreements --silent" `
            -PassThru -NoNewWindow -ErrorAction Stop
        $finished = $proc.WaitForExit(120000)
        if (-not $finished) {
            try { $proc.Kill() } catch {}
            Write-Warn "winget timed out (120s), falling back to mirror download..."
            $global:InstalledViaWinget = $false
            return
        }
        # 0 = success; -1978335189 (0x8A150B2B) = no applicable upgrade (already up to date)
        $alreadyUpToDate = ($proc.ExitCode -eq -1978335189)
        if ($proc.ExitCode -eq 0 -or $alreadyUpToDate) {
            if ($alreadyUpToDate) {
                Write-Ok "Claude Code is already up to date (winget)."
            } else {
                Write-Ok "Claude Code installed via winget."
            }
            Write-Info "Note: winget installation does not set up shell integration or auto-update."
            Write-Info "To upgrade later: winget upgrade Anthropic.ClaudeCode"
            $global:InstalledViaWinget = $true
            # Refresh current session PATH so claude is usable immediately
            $mp = [Environment]::GetEnvironmentVariable("Path", "Machine"); if ($null -eq $mp) { $mp = "" }
            $up = [Environment]::GetEnvironmentVariable("Path", "User");    if ($null -eq $up) { $up = "" }
            $env:Path = "$mp;$up"
        } else {
            Write-Warn "winget failed (exit $($proc.ExitCode)), falling back to mirror download..."
            $global:InstalledViaWinget = $false
        }
    } catch {
        Write-Warn "winget failed: $($_.Exception.Message), falling back to mirror download..."
        $global:InstalledViaWinget = $false
    }
}

# -- Ensure Node.js >= 18 (npm install path) -----------------------------------
function Ensure-Node {
    $minMajor = 18
    $currentMajor = 0
    $nodeWasMissing = $true

    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeCmd) {
        try {
            $ver = (& $nodeCmd.Source --version 2>&1) -replace '^v', ''
            $currentMajor = [int]($ver -split '\.')[0]
            $nodeWasMissing = $false
        } catch {}
    }

    if ($currentMajor -ge $minMajor) {
        Write-Ok "Node.js $($currentMajor).x found."
        return
    }

    Write-Step "Installing Node.js..."

    # Fetch latest LTS version from npmmirror
    $nodeVer = "v22.14.0"
    try {
        $list = Invoke-RestMethod -Uri "https://npmmirror.com/mirrors/node/index.json" `
            -TimeoutSec 8 -ErrorAction Stop
        $lts = $list | Where-Object { $_.lts -and $_.lts -ne $false } |
            Sort-Object { [Version]($_.version -replace '^v','') } -Descending |
            Select-Object -First 1
        if ($lts) { $nodeVer = $lts.version }
    } catch {
        Write-Info "Could not fetch Node.js version list, using $nodeVer"
    }

    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
    $msiName = "node-$nodeVer-$arch.msi"

    $msiUrls = @(
        "https://npmmirror.com/mirrors/node/$nodeVer/$msiName",
        "https://nodejs.org/dist/$nodeVer/$msiName"
    )

    $tmpMsi = "$env:TEMP\$msiName"
    $downloaded = $false
    foreach ($url in $msiUrls) {
        if (Invoke-Download -Url $url -OutFile $tmpMsi -Label "Node.js $nodeVer") {
            $downloaded = $true; break
        }
    }

    $msiOk = $false
    if ($downloaded) {
        Write-Info "Installing Node.js silently..."
        try {
            $proc = Start-Process msiexec.exe `
                -ArgumentList "/i `"$tmpMsi`" /qn /norestart" `
                -Wait -PassThru -ErrorAction Stop
            if ($proc.ExitCode -eq 0) {
                Write-Ok "Node.js $nodeVer installed."
                $msiOk = $true
                if ($nodeWasMissing) {
                    Write-InstallerMarker -Path $NODE_INSTALL_MARKER -Signature (Get-InstallEntrySignature (Find-NodeInstallEntry))
                }
            } else {
                Write-Warn "Node.js MSI exited with code $($proc.ExitCode)."
            }
        } catch {
            Write-Warn "Failed to run Node.js installer: $($_.Exception.Message)"
        }
        Remove-Item $tmpMsi -Force -ErrorAction SilentlyContinue
    } else {
        Write-Warn "Node.js download failed."
    }

    if (-not $msiOk) {
        Write-Info "Trying winget fallback for Node.js..."
        $wingetExe = Get-WingetExe
        if ($wingetExe) {
            try {
                $proc = Start-Process $wingetExe `
                    -ArgumentList "install -e --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements --silent" `
                    -PassThru -NoNewWindow -ErrorAction Stop
                $proc.WaitForExit(120000) | Out-Null
                if ($proc.ExitCode -eq 0) {
                    Write-Ok "Node.js installed via winget."
                    if ($nodeWasMissing) {
                        Write-InstallerMarker -Path $NODE_INSTALL_MARKER -Signature (Get-InstallEntrySignature (Find-NodeInstallEntry))
                    }
                }
                else { Write-Warn "winget Node.js install exited with code $($proc.ExitCode)." }
            } catch {
                Write-Warn "winget fallback failed: $($_.Exception.Message)"
                Write-Warn "Please install Node.js 18+ manually: https://nodejs.org"
            }
        } else {
            Write-Warn "winget not found. Please install Node.js 18+ manually: https://nodejs.org"
        }
    }

    # Refresh PATH so node/npm are available in current session
    $mp = [Environment]::GetEnvironmentVariable("Path", "Machine"); if ($null -eq $mp) { $mp = "" }
    $up = [Environment]::GetEnvironmentVariable("Path", "User");    if ($null -eq $up) { $up = "" }
    $env:Path = "$mp;$up"

    $nodeCmd2 = Get-Command node -ErrorAction SilentlyContinue
    if (-not $nodeCmd2) {
        # Try common install locations
        foreach ($p in @(
            "$env:ProgramFiles\nodejs\node.exe",
            "$env:LOCALAPPDATA\Programs\nodejs\node.exe"
        )) {
            if (Test-Path $p) {
                $dir = Split-Path $p -Parent
                $env:Path = "$env:Path;$dir"
                break
            }
        }
    }

    $nodeCmd3 = Get-Command node -ErrorAction SilentlyContinue
    if (-not $nodeCmd3) {
        Exit-WithError "Node.js installation failed. Please install Node.js 18+ manually."
    }
    try {
        $verNow = (& $nodeCmd3.Source --version 2>&1) -replace '^v', ''
        $majorNow = [int]($verNow -split '\.')[0]
        if ($majorNow -lt $minMajor) {
            Exit-WithError "Node.js $verNow is too old. Please install Node.js 18+ manually."
        }
        Write-Ok "Node.js v$verNow ready."
    } catch {
        Exit-WithError "Unable to validate Node.js version after installation."
    }
}

# -- npm install path ----------------------------------------------------------
function Install-ViaNpm {
    Ensure-Node

    $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npmCmd) {
        # npm should be alongside node; check common paths
        foreach ($p in @(
            "$env:ProgramFiles\nodejs\npm.cmd",
            "$env:LOCALAPPDATA\Programs\nodejs\npm.cmd"
        )) {
            if (Test-Path $p) {
                $dir = Split-Path $p -Parent
                if ($env:Path -notlike "*$dir*") { $env:Path = "$env:Path;$dir" }
                break
            }
        }
        $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
    }

    if (-not $npmCmd) {
        Exit-WithError "npm not found after Node.js installation. Please install Node.js 18+ manually."
    }

    Write-Step "Configuring npm and installing Claude Code..."
    & $npmCmd.Source config set registry "https://registry.npmmirror.com" 2>&1 | Out-Null
    & $npmCmd.Source i -g "@anthropic-ai/claude-code" --registry=https://registry.npmmirror.com

    # Add %APPDATA%\npm to user PATH if not present
    $npmBin = "$env:APPDATA\npm"
    $currentUp = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($null -eq $currentUp) { $currentUp = "" }
    if (-not $currentUp.Contains($npmBin)) {
        [Environment]::SetEnvironmentVariable("Path", "$currentUp;$npmBin", "User")
        New-Item -ItemType Directory -Force -Path (Split-Path $NPM_PATH_MARKER -Parent) | Out-Null
        New-Item -ItemType File -Force -Path $NPM_PATH_MARKER | Out-Null
        Write-Ok "Added to PATH: $npmBin"
    }
    if ($env:Path -notlike "*$npmBin*") { $env:Path = "$env:Path;$npmBin" }

    # Disable claude.ps1 shim to avoid execution policy issues
    $shimPs1 = "$npmBin\claude.ps1"
    if (Test-Path $shimPs1) {
        Rename-Item $shimPs1 "$npmBin\claude.ps1.disabled" -ErrorAction SilentlyContinue
        Write-Info "Renamed claude.ps1 to claude.ps1.disabled (claude.cmd shim works without it)."
    }

    $global:InstalledViaNpm    = $true
    $global:InstallMethod      = "npm"
    $global:InstalledClaudeExe = "$npmBin\claude.cmd"

    $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($claudeCmd) {
        Write-Ok "Claude Code installed: $($claudeCmd.Source)"
        $global:InstalledClaudeExe = $claudeCmd.Source
    } else {
        Write-Warn "claude not in PATH yet. Open a new terminal after installation."
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

    # 3. Version check (shared by both install methods)
    $targetVersion    = Get-LatestVersion
    $installedVersion = Get-InstalledVersion
    $skipInstall      = $false
    if ($installedVersion -eq $targetVersion) {
        Write-Ok "Claude Code v$targetVersion is already up to date."
        $skipInstall = $true
        # If claude is not in PATH but exists at LOCAL_BIN, fix PATH now
        $LOCAL_BIN = "$env:USERPROFILE\.local\bin"
        if (-not (Get-Command claude -ErrorAction SilentlyContinue) -and (Test-Path "$LOCAL_BIN\claude.exe")) {
            $currentUp = [Environment]::GetEnvironmentVariable("Path", "User")
            if ($null -eq $currentUp) { $currentUp = "" }
            if (-not $currentUp.Contains($LOCAL_BIN)) {
                [Environment]::SetEnvironmentVariable("Path", "$currentUp;$LOCAL_BIN", "User")
                Write-Ok "Added to PATH: $LOCAL_BIN"
            }
            $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
            $isChildProcess = [Environment]::GetCommandLineArgs() | Where-Object { $_ -match '(?i)^-File$' }
            if ($isChildProcess) {
                Write-Warn "Please open a NEW terminal to use claude."
            } else {
                Write-Ok "claude is now available in this session."
            }
        }
    } elseif ($installedVersion) {
        Write-Info "Upgrading: v$installedVersion -> v$targetVersion"
    } else {
        Write-Info "Installing Claude Code v$targetVersion"
    }

    if (-not $skipInstall) {
        # 4. Choose installation method
        Write-Host ""
        Write-Host "Select installation method:" -ForegroundColor Cyan
        Write-Host "  [1] Native Install (Recommended) -- downloads official binary, sets up auto-update"
        Write-Host "  [2] winget                        -- uses Windows Package Manager"
        Write-Host "  [3] npm (via npmmirror)           -- installs via npm registry"
        Write-Host ""
        $methodChoice = Read-Host "Enter choice [1]"
        if ($methodChoice -eq "2") {
            $wingetExe = Get-WingetExe
            if (-not $wingetExe) {
                Write-Info "winget not found, installing it automatically..."
                Install-Winget
                $wingetExe = Get-WingetExe
            }
            if ($wingetExe) {
                Ensure-WingetAlias -WingetExe $wingetExe
                Install-ViaWinget -WingetExe $wingetExe
            } else {
                Write-Warn "winget is not available on this system, falling back to Native Install."
            }
        } elseif ($methodChoice -eq "3") {
            Install-ViaNpm
        }
    }

    if (-not $global:InstalledViaWinget -and -not $skipInstall) {
        # 5. Select fastest GitHub mirror for any path that may download GitHub releases
        Select-Mirror -Version $targetVersion
    }

    # 6. Ensure Git (all install methods need Git for Claude Code to function)
    Ensure-Git

    if (-not $global:InstalledViaWinget -and -not $global:InstalledViaNpm -and -not $skipInstall) {
        # 7. Prepare download dir (aligns with official: ~/.claude/downloads)
        New-Item -ItemType Directory -Force -Path $DOWNLOAD_DIR | Out-Null

        $fileName    = "claude-$targetVersion-$platform.exe"
        $binaryPath  = "$DOWNLOAD_DIR\$fileName"
        $manifestFile = "$DOWNLOAD_DIR\manifest-$targetVersion.json"

        # Build download URLs from selected GitHub mirror
        $dlUrl      = "$global:SelectedMirror/$RELEASES_REPO/releases/download/v$targetVersion/$fileName"
        $manifestUrl = "$global:SelectedMirror/$RELEASES_REPO/releases/download/v$targetVersion/manifest-$targetVersion.json"

        # 8. Download manifest.json (for cache verification)
        $manifestOk = $false
        if (Test-Path $manifestFile) {
            $manifestOk = $true
        } else {
            $manifestOk = Invoke-DownloadMirror `
                -Path "/$RELEASES_REPO/releases/download/v$targetVersion/manifest-$targetVersion.json" `
                -OutFile $manifestFile -Label "manifest.json"
        }

        # 9. Download binary (with cache)
        $needDownload = $true
        if (Test-Path $binaryPath) {
            if ($manifestOk) {
                if (Test-Checksum -FilePath $binaryPath -ManifestFile $manifestFile -Platform $platform) {
                    Write-Step "Using cached $fileName (checksum OK)..."
                    $needDownload = $false
                } else {
                    Write-Warn "Cached file checksum mismatch, re-downloading..."
                    Remove-Item $binaryPath -Force -ErrorAction SilentlyContinue
                }
            } else {
                Write-Step "Using cached $fileName (manifest unavailable)..."
                $needDownload = $false
            }
        }

        if ($needDownload) {
            Write-Step "Downloading $fileName..."
            Write-Info "Large binary (~230 MB), no progress bar -- please wait..."

            $dlOk = Invoke-DownloadMirror `
                -Path "/$RELEASES_REPO/releases/download/v$targetVersion/$fileName" `
                -OutFile $binaryPath -Label "Claude Code binary"

            if (-not $dlOk) {
                Exit-WithError "Download failed. Try a different mirror or check your connection."
            }

            if (-not $NoVerify -and $manifestOk) {
                if (-not (Test-Checksum -FilePath $binaryPath -ManifestFile $manifestFile -Platform $platform)) {
                    Remove-Item $binaryPath -Force -ErrorAction SilentlyContinue
                    Exit-WithError "Checksum verification failed. The file may be corrupted."
                }
            }
        }

        # 10. Remove Zone.Identifier (cached files may not have been unblocked)
        Unblock-File -Path $binaryPath -ErrorAction SilentlyContinue

        # 11. Run install; fall back to manual setup if it fails (e.g. CDN unreachable in China)
        Write-Step "Setting up Claude Code..."
        $installTimeout = 25
        [void][int]::TryParse($env:CLAUDE_INSTALL_TIMEOUT, [ref]$installTimeout)
        if ($installTimeout -le 0) { $installTimeout = 25 }

        $installMode = "$env:CLAUDE_INSTALL_MODE".ToLowerInvariant()
        if ($installMode -notin @("auto", "force", "skip")) { $installMode = "auto" }

        $runClaudeInstall = $true
        if ($installMode -eq "skip") {
            $runClaudeInstall = $false
            Write-Warn "CLAUDE_INSTALL_MODE=skip -- using manual fallback installation."
        } elseif ($installMode -eq "auto" -and -not (Test-AnthropicApiReachable)) {
            $runClaudeInstall = $false
            Write-Warn "Anthropic API unreachable -- skipping 'claude install' and using manual fallback."
        }

        if ($runClaudeInstall) {
            Write-Info "Running claude install (may download additional components)..."
            Write-Info "Mode: $installMode"
            Write-Info "Please wait up to ${installTimeout}s -- if it fails, manual fallback will be used."

            $installJob = Start-Job -ScriptBlock {
                param($b)
                $OutputEncoding           = [System.Text.Encoding]::UTF8
                [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
                & $b install 2>&1
            } -ArgumentList $binaryPath

            $done = Wait-Job $installJob -Timeout $installTimeout
            if ($done) {
                @(Receive-Job $installJob -ErrorAction SilentlyContinue) |
                    ForEach-Object { if ($_) { Write-Host "  $_" } }
                Remove-Job $installJob -Force -ErrorAction SilentlyContinue
            } else {
                Stop-Job  $installJob -ErrorAction SilentlyContinue
                Remove-Job $installJob -Force -ErrorAction SilentlyContinue
                Write-Warn "claude install timed out (${installTimeout}s). Switching to manual fallback."
            }
        }

        # Unified PATH setup -- regardless of whether claude install succeeded or not
        $LOCAL_BIN = "$env:USERPROFILE\.local\bin"
        $localExe  = "$LOCAL_BIN\claude.exe"
        New-Item -ItemType Directory -Force -Path $LOCAL_BIN | Out-Null

        if ((Test-Path $localExe) -and (& $localExe --version 2>$null)) {
            $global:InstallMethod = "official"
            $global:InstalledClaudeExe = $localExe
            Write-Ok "Claude Code installed by claude install: $localExe"
        } else {
            Write-Warn "claude install did not place binary, using downloaded binary as fallback."
            Copy-Item $binaryPath $localExe -Force
            Unblock-File -Path $localExe -ErrorAction SilentlyContinue
            $global:InstallMethod = "fallback"
            $global:InstalledClaudeExe = $localExe
            Write-Ok "Claude Code installed (fallback): $localExe"
        }

        # Add LOCAL_BIN to user PATH if not already there
        $currentUp = [Environment]::GetEnvironmentVariable("Path", "User")
        if ($null -eq $currentUp) { $currentUp = "" }
        if (-not $currentUp.Contains($LOCAL_BIN)) {
            [Environment]::SetEnvironmentVariable("Path", "$currentUp;$LOCAL_BIN", "User")
            Write-Ok "Added to PATH: $LOCAL_BIN"
        }

        # Refresh current session PATH so claude is usable immediately
        $mp = [Environment]::GetEnvironmentVariable("Path", "Machine"); if ($null -eq $mp) { $mp = "" }
        $up = [Environment]::GetEnvironmentVariable("Path", "User");    if ($null -eq $up) { $up = "" }
        $env:Path = "$mp;$up"

        # Detect if running as a child process (powershell -File ...) vs in-session (iex)
        # When launched via -File, PATH changes cannot propagate back to the parent terminal.
        $isChildProcess = [Environment]::GetCommandLineArgs() | Where-Object { $_ -match '(?i)^-File$' }
        if ($isChildProcess) {
            Write-Ok "PATH updated in system registry."
            Write-Warn "You ran the script via 'powershell -File'. Please open a NEW terminal to use claude."
            Write-Info "Or run this in current terminal to refresh PATH:"
            Write-Host '  $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")' -ForegroundColor Yellow
        } else {
            Write-Ok "claude is available in this session immediately."
        }
        Write-Info "New terminal windows will also have claude in PATH automatically."
    }

    # 12. Optional: CC Switch
    Write-Host ""
    $ccSwitchInstalled = $false
    if (Test-CcSwitchInstalled) {
        Write-Ok "CC Switch is already installed."
        $ccSwitchInstalled = $true
    } else {
        $installCcSwitch = Read-Host "Install CC Switch (API Provider switcher)? [y/N]"
        if ($installCcSwitch -match '^[Yy]') {
            $ccSwitchInstalled = Install-CcSwitch
        }
    }

    # 13. API / Provider configuration
    Configure-ApiKey -CcSwitchInstalled $ccSwitchInstalled

    # 14. Done
    Write-Host ""
    Write-Output "[OK] Installation complete!"
    Write-Host ""
    if ($global:InstallMethod -eq "official") {
        Write-Host "  Install mode: official (via claude install, auto-update enabled)"
    } elseif ($global:InstallMethod -eq "fallback") {
        Write-Host "  Install mode: fallback (direct binary copy, no auto-update)"
    } elseif ($global:InstallMethod -eq "npm") {
        Write-Host "  Install mode: npm (via npmmirror)"
        Write-Host "  Upgrade:      npm update -g @anthropic-ai/claude-code"
    }
    if ($global:InstalledClaudeExe) {
        Write-Host "  Binary: $global:InstalledClaudeExe"
    }
    if ($global:InstallMethod) {
        Write-Host ""
    }
    Write-Host "  Quick start:"
    Write-Host "    claude            -- start Claude Code"
    Write-Host "    claude --version  -- verify installation"
    Write-Host ""
    if ($ccSwitchInstalled) {
        Write-Host "  CC Switch: open from Start Menu to configure your API Provider." -ForegroundColor Cyan
        Write-Host ""
    }
    Write-Host "  To upgrade:   powershell -ExecutionPolicy Bypass -File install.ps1"
    Write-Host "  To uninstall: powershell -ExecutionPolicy Bypass -File uninstall.ps1"
    Write-Host ""
}

Main
