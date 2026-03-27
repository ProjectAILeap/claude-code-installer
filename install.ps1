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
if (-not (Get-Variable 'NoVerify'   -ErrorAction SilentlyContinue)) { $NoVerify   = $false }
if (-not (Get-Variable 'UseWinget'  -ErrorAction SilentlyContinue)) { $UseWinget  = $false }

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
$GIT_MIN_VER      = [Version]"2.40.0"
$GIT_FALLBACK_VER = "2.47.1"
$GIT_FALLBACK_TAG = "v2.47.1.windows.1"

$GCS_BUCKET = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"

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
$global:SelectedMirror     = ""
$global:GithubMirror       = ""   # fastest non-GCS mirror (used for CC Switch / Git)
$global:IsGCS              = $false
$global:InstalledViaWinget = $false

function Select-Mirror {
    param([string]$Version)

    Write-Step "Testing mirror speeds (GCS + GitHub mirrors)..."

    # Use HttpClient async tasks (in-process, no Start-Job overhead).
    # ResponseHeadersRead = stop as soon as headers arrive, don't download body.
    Add-Type -AssemblyName System.Net.Http   # required on PS 5.1 / .NET Framework
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $true
    $client  = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [System.TimeSpan]::FromSeconds(20)

    $allSources = @($GCS_BUCKET) + $MIRRORS
    $tasks = [ordered]@{}
    $sw    = [ordered]@{}

    foreach ($m in $allSources) {
        $url = if ($m -eq $GCS_BUCKET) {
            "$GCS_BUCKET/$Version/manifest.json"
        } else {
            "$m/$RELEASES_REPO/releases/download/v$Version/sha256sums.txt"
        }
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
        $t = if ($r.Mirror -eq $GCS_BUCKET) { "GCS (official)" } else {
            $r.Mirror -replace 'https://([^/]+)(/.*)?$','$1'
        }
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
        $global:IsGCS = ($best.Mirror -eq $GCS_BUCKET)
        $tag = if ($global:IsGCS) { "GCS (official)" } else {
            $best.Mirror -replace 'https://([^/]+)(/.*)?$','$1'
        }
        Write-Ok "Selected: $tag ($($best.Ms) ms)"

        # Track fastest non-GCS mirror for CC Switch / Git downloads
        $firstGithub = $reachable | Where-Object { $_.Mirror -ne $GCS_BUCKET } | Select-Object -First 1
        $global:GithubMirror = if ($firstGithub) { $firstGithub.Mirror } else { "https://ghfast.top/https://github.com" }
    } else {
        $global:SelectedMirror = "https://ghfast.top/https://github.com"
        $global:GithubMirror   = "https://ghfast.top/https://github.com"
        $global:IsGCS = $false
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

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

    # Non-admin: use winget to avoid UAC dialog (winget installs via its own elevated service).
    # If winget is missing, install it first, then use it for Git.
    # Admin: skip winget, go straight to exe (already elevated, no UAC).
    $gitInstalledOk = $false
    if (-not $isAdmin) {
        $wingetExe = Get-WingetExe
        if (-not $wingetExe) {
            Write-Info "  winget not found, installing it first (no UAC required)..."
            Install-Winget
            $wingetExe = Get-WingetExe
        }
        if ($wingetExe) {
            Write-Info "  Installing Git via winget (no UAC required)..."
            try {
                & $wingetExe install -e --id Git.Git --source winget `
                    --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
                Write-Ok "Git installed via winget."
                $gitInstalledOk = $true
            } catch {
                Write-Warn "  winget failed: $($_.Exception.Message), falling back to installer..."
            }
        }
    }

    if (-not $gitInstalledOk) {
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
                # Admin: system-wide install, no UAC needed (already elevated)
                # Non-admin: /CURRENTUSER installs to %LOCALAPPDATA%, may still show UAC on some Git versions
                $gitArgs = if ($isAdmin) {
                    '/VERYSILENT /NORESTART /NOCANCEL /SP- /SUPPRESSMSGBOXES /CLOSEAPPLICATIONS /COMPONENTS="icons,ext\reg\shellhere,assoc,assoc_sh"'
                } else {
                    '/VERYSILENT /NORESTART /NOCANCEL /SP- /SUPPRESSMSGBOXES /CLOSEAPPLICATIONS /CURRENTUSER /COMPONENTS="icons,ext\reg\shellhere,assoc,assoc_sh"'
                }
                $proc = Start-Process -FilePath $tmpExe -ArgumentList $gitArgs -Wait -PassThru -ErrorAction Stop
                if ($proc.ExitCode -eq 0) { Write-Ok "Git installed." }
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

# -- Winget helpers ------------------------------------------------------------
function Get-WingetExe {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $pkg = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($pkg) {
        $exe = Join-Path $pkg.InstallLocation "winget.exe"
        if (Test-Path $exe) { return $exe }
    }
    return $null
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
    } catch {
        Write-Warn "Failed to install winget: $($_.Exception.Message)"
    }
}

# -- Optional: winget install path ---------------------------------------------
function Install-ViaWinget {
    Write-Step "Installing Claude Code via winget..."
    try {
        $proc = Start-Process winget `
            -ArgumentList "install -e --id Anthropic.ClaudeCode --source winget --accept-source-agreements --accept-package-agreements --silent" `
            -Wait -PassThru -ErrorAction Stop
        if ($proc.ExitCode -eq 0) {
            Write-Ok "Claude Code installed via winget."
            Write-Info "Note: winget installation does not set up shell integration or auto-update."
            Write-Info "To upgrade later: winget upgrade Anthropic.ClaudeCode"
            $global:InstalledViaWinget = $true
        } else {
            Write-Warn "winget failed (exit $($proc.ExitCode)), falling back to mirror download..."
            $global:InstalledViaWinget = $false
        }
    } catch {
        Write-Warn "winget failed: $($_.Exception.Message), falling back to mirror download..."
        $global:InstalledViaWinget = $false
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

    # 2.5. Optional: winget path (enabled via $UseWinget = $true before iex, or -UseWinget flag)
    if ($UseWinget) {
        Write-Host ""
        $wingetExe = Get-WingetExe
        if (-not $wingetExe) {
            Write-Warn "winget not found on this system."
            $ans = Read-Host "  Install winget (Windows Package Manager) first? [y/N]"
            if ($ans -match '^[Yy]') {
                Install-Winget
                $wingetExe = Get-WingetExe
                if (-not $wingetExe) {
                    Write-Warn "winget still not available, falling back to mirror download."
                }
            }
        } else {
            Write-Info "winget available: $wingetExe"
        }

        if ($wingetExe) {
            $ans = Read-Host "  Install Claude Code via winget? [y/N]"
            if ($ans -match '^[Yy]') {
                Install-ViaWinget
            }
        }
    }

    if (-not $global:InstalledViaWinget) {
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

        # 5. Select fastest mirror (GCS + GitHub mirrors)
        Select-Mirror -Version $targetVersion
    }

    # 6. Ensure Git
    Ensure-Git

    if (-not $global:InstalledViaWinget) {
        # 7. Prepare download dir (aligns with official: ~/.claude/downloads)
        New-Item -ItemType Directory -Force -Path $DOWNLOAD_DIR | Out-Null

        $fileName    = "claude-$targetVersion-$platform.exe"
        $binaryPath  = "$DOWNLOAD_DIR\$fileName"
        $manifestFile = "$DOWNLOAD_DIR\manifest-$targetVersion.json"

        # Build download URLs based on selected source
        if ($global:IsGCS) {
            $dlUrl      = "$GCS_BUCKET/$targetVersion/$platform/claude.exe"
            $manifestUrl = "$GCS_BUCKET/$targetVersion/manifest.json"
        } else {
            $dlUrl      = "$global:SelectedMirror/$RELEASES_REPO/releases/download/v$targetVersion/$fileName"
            $manifestUrl = "$global:SelectedMirror/$RELEASES_REPO/releases/download/v$targetVersion/manifest-$targetVersion.json"
        }

        # 8. Download manifest.json (for cache verification)
        $manifestOk = $false
        if (Test-Path $manifestFile) {
            $manifestOk = $true
        } else {
            if ($global:IsGCS) {
                $manifestOk = Invoke-Download -Url $manifestUrl -OutFile $manifestFile -Label "manifest.json" -RetryCount 2
                if (-not $manifestOk) {
                    Write-Warn "GCS manifest unavailable, trying GitHub mirror..."
                    $fbManifestUrl = "$global:GithubMirror/$RELEASES_REPO/releases/download/v$targetVersion/manifest-$targetVersion.json"
                    $manifestOk = Invoke-Download -Url $fbManifestUrl -OutFile $manifestFile -Label "manifest.json (fallback)" -RetryCount 2
                }
            } else {
                $manifestOk = Invoke-DownloadMirror `
                    -Path "/$RELEASES_REPO/releases/download/v$targetVersion/manifest-$targetVersion.json" `
                    -OutFile $manifestFile -Label "manifest.json"
            }
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

            $dlOk = $false
            if ($global:IsGCS) {
                # GCS may be throttled/blocked in China for large files even if headers are fast.
                # Use a short timeout (30s) and single attempt so fallback to GitHub is quick.
                $dlOk = Invoke-Download -Url $dlUrl -OutFile $binaryPath -Label "Claude Code binary (GCS)" -TimeoutSec 30 -RetryCount 1
                if (-not $dlOk) {
                    Write-Warn "GCS download failed, falling back to GitHub mirror..."
                    $global:IsGCS = $false
                    $dlUrl = "$global:GithubMirror/$RELEASES_REPO/releases/download/v$targetVersion/$fileName"
                    # Also re-fetch manifest from GitHub if it came from GCS
                    if ($manifestOk) {
                        $fbManifestUrl = "$global:GithubMirror/$RELEASES_REPO/releases/download/v$targetVersion/manifest-$targetVersion.json"
                        Remove-Item $manifestFile -Force -ErrorAction SilentlyContinue
                        $manifestOk = Invoke-Download -Url $fbManifestUrl -OutFile $manifestFile -Label "manifest.json (GitHub)" -RetryCount 2
                    }
                    $dlOk = Invoke-DownloadMirror `
                        -Path "/$RELEASES_REPO/releases/download/v$targetVersion/$fileName" `
                        -OutFile $binaryPath -Label "Claude Code binary"
                }
            } else {
                $dlOk = Invoke-DownloadMirror `
                    -Path "/$RELEASES_REPO/releases/download/v$targetVersion/$fileName" `
                    -OutFile $binaryPath -Label "Claude Code binary"
            }

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
        Write-Info "Running claude install (may download additional components)..."
        Write-Info "Please wait up to 90s -- if CDN is unreachable, manual fallback will be used."

        $installJob = Start-Job -ScriptBlock {
            param($b)
            $OutputEncoding           = [System.Text.Encoding]::UTF8
            [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
            & $b install 2>&1
        } -ArgumentList $binaryPath

        $done = Wait-Job $installJob -Timeout 90
        if ($done) {
            @(Receive-Job $installJob -ErrorAction SilentlyContinue) |
                ForEach-Object { if ($_) { Write-Host "  $_" } }
            Remove-Job $installJob -Force -ErrorAction SilentlyContinue
        } else {
            Stop-Job  $installJob -ErrorAction SilentlyContinue
            Remove-Job $installJob -Force -ErrorAction SilentlyContinue
            Write-Warn "claude install timed out (90s). CDN may be unreachable -- switching to manual fallback."
        }

        # Unified PATH setup -- regardless of whether claude install succeeded or not
        $LOCAL_BIN = "$env:USERPROFILE\.local\bin"
        $localExe  = "$LOCAL_BIN\claude.exe"
        New-Item -ItemType Directory -Force -Path $LOCAL_BIN | Out-Null

        if (Test-Path $localExe) {
            # claude install placed the binary (with native build) -- keep it, just fix PATH
            Write-Ok "Claude Code installed by claude install: $localExe"
        } else {
            # claude install failed completely -- copy raw binary as fallback
            Write-Warn "claude install did not place binary, using downloaded binary as fallback."
            Copy-Item $binaryPath $localExe -Force
            Unblock-File -Path $localExe -ErrorAction SilentlyContinue
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
    Write-Host "  To upgrade:   powershell -ExecutionPolicy Bypass -File install.ps1"
    Write-Host "  To uninstall: powershell -ExecutionPolicy Bypass -File uninstall.ps1"
    Write-Host ""
}

Main
