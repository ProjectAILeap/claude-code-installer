#Requires -Version 5.1
<#
.SYNOPSIS
    install.ps1 / uninstall.ps1 测试脚本 — ProjectAILeap/claude-code-installer
.DESCRIPTION
    用法:
      pwsh -File tests/test.ps1          # 运行全部层（第四层需要 Windows）
      pwsh -File tests/test.ps1 1        # 只运行第一层
      pwsh -File tests/test.ps1 1 2 3    # 运行指定层

    通过 Docker 运行（Linux / macOS）:
      docker run --rm -v "$PWD:/scripts" mcr.microsoft.com/powershell `
        pwsh -File /scripts/tests/test.ps1 1 2 3
#>

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Layers
)

$ErrorActionPreference = "Stop"
$RepoDir       = Split-Path $PSScriptRoot -Parent
$INSTALL_PS1   = Join-Path $RepoDir "install.ps1"
$UNINSTALL_PS1 = Join-Path $RepoDir "uninstall.ps1"

$script:FAILURES = 0

function Pass { param($msg) Write-Host "  [PASS]  $msg" -ForegroundColor Green }
function Fail { param($msg) Write-Host "  [FAIL]  $msg" -ForegroundColor Red; $script:FAILURES++ }
function Info { param($msg) Write-Host "  [INFO]  $msg" -ForegroundColor Gray }
function Step { param($msg) Write-Host "`n>> $msg" -ForegroundColor Cyan }

# 在脚本作用域 dot-source install.ps1（去掉 Main 调用），使所有函数和常量可用
$_c = (Get-Content $INSTALL_PS1 -Raw) -replace '(?m)^Main\s*$', '# Main (disabled for testing)'
. ([scriptblock]::Create($_c))
Remove-Variable _c

# ── 第一层：语法检查 ──────────────────────────────────────────────────────────
function Layer1 {
    Step "第一层：语法检查"

    foreach ($file in @($INSTALL_PS1, $UNINSTALL_PS1)) {
        $name = Split-Path $file -Leaf
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $file, [ref]$null, [ref]$parseErrors)
        if ($parseErrors.Count -eq 0) {
            Pass "$name 语法检查"
        } else {
            $parseErrors | ForEach-Object { Info "  $_" }
            Fail "$name 语法检查（见上方错误）"
        }
    }

    if (Get-Module -ListAvailable PSScriptAnalyzer -ErrorAction SilentlyContinue) {
        foreach ($file in @($INSTALL_PS1, $UNINSTALL_PS1)) {
            $name = Split-Path $file -Leaf
            $issues = Invoke-ScriptAnalyzer -Path $file -Severity Error, Warning 2>$null
            if (-not $issues) {
                Pass "$name PSScriptAnalyzer"
            } else {
                $issues | ForEach-Object { Info "  $($_.RuleName): $($_.Message)" }
                Fail "$name PSScriptAnalyzer（$($issues.Count) 项）"
            }
        }
    } else {
        Info "PSScriptAnalyzer 未安装，跳过（Install-Module PSScriptAnalyzer）"
    }
}

# ── 第二层：函数级单测（需网络）──────────────────────────────────────────────
function Layer2 {
    Step "第二层：函数级单测（需网络）"

    # Get-LatestVersion
    try {
        $v = Get-LatestVersion
        if ($v -match '^\d+\.\d+\.\d+$') {
            Pass "Get-LatestVersion → v$v"
        } else {
            Fail "Get-LatestVersion 返回非预期值: '$v'"
        }
    } catch {
        Fail "Get-LatestVersion 异常: $($_.Exception.Message)"
    }

    # Select-Mirror
    try {
        Select-Mirror
        if ($global:SelectedMirror -match '^https://') {
            $tag = $global:SelectedMirror -replace 'https://([^/]+).*', '$1'
            Pass "Select-Mirror → SelectedMirror = $tag"
        } else {
            Fail "Select-Mirror: SelectedMirror 无效: '$global:SelectedMirror'"
        }
        if ($global:GithubMirror -match '^https://') {
            $tag = $global:GithubMirror -replace 'https://([^/]+).*', '$1'
            Pass "Select-Mirror → GithubMirror = $tag"
        } else {
            Fail "Select-Mirror: GithubMirror 未设置"
        }
        Info "IsGCS = $global:IsGCS"
        if ($global:IsGCS) {
            Info "GCS 被选中（境外网络，符合预期）"
        } else {
            Info "GCS 未选中（中国网络，符合预期）"
        }
    } catch {
        Fail "Select-Mirror 异常: $($_.Exception.Message)"
    }

    # Get-InstalledVersion（不依赖网络）
    try {
        $iv = Get-InstalledVersion
        if ($iv -eq '' -or $iv -match '^\d+\.\d+\.\d+$') {
            Pass "Get-InstalledVersion → $(if ($iv) { "v$iv" } else { '(未安装)' })"
        } else {
            Fail "Get-InstalledVersion 返回非预期值: '$iv'"
        }
    } catch {
        Fail "Get-InstalledVersion 异常: $($_.Exception.Message)"
    }

    # Get-DownloadUrl 使用 GithubMirror（不用 GCS）
    $global:GithubMirror = "https://ghfast.top/https://github.com"
    $url = Get-DownloadUrl "/foo/bar"
    if ($url -eq "https://ghfast.top/https://github.com/foo/bar") {
        Pass "Get-DownloadUrl → $url"
    } else {
        Fail "Get-DownloadUrl 返回非预期值: '$url'"
    }
}

# ── 第三层：逻辑模拟（无需网络）──────────────────────────────────────────────
function Layer3 {
    Step "第三层：逻辑模拟"

    # Test-Checksum：正确校验和 → 通过
    $manifestFile = New-TemporaryFile
    $binaryFile   = New-TemporaryFile
    "hello" | Set-Content $binaryFile -NoNewline
    $hash = (Get-FileHash $binaryFile -Algorithm SHA256).Hash.ToLower()
    "{`"platforms`":{`"win32-x64`":{`"checksum`":`"$hash`",`"size`":5}}}" |
        Set-Content $manifestFile
    $r = Test-Checksum -FilePath $binaryFile -ManifestFile $manifestFile -Platform "win32-x64"
    if ($r) { Pass "Test-Checksum：正确校验和 → 通过" } else { Fail "Test-Checksum：正确校验和应通过" }
    Remove-Item $manifestFile, $binaryFile -Force

    # Test-Checksum：错误校验和 → 拒绝
    $manifestFile = New-TemporaryFile
    $binaryFile   = New-TemporaryFile
    "hello" | Set-Content $binaryFile -NoNewline
    '{"platforms":{"win32-x64":{"checksum":"0000000000000000000000000000000000000000000000000000000000000000","size":5}}}' |
        Set-Content $manifestFile
    $r = Test-Checksum -FilePath $binaryFile -ManifestFile $manifestFile -Platform "win32-x64"
    if (-not $r) { Pass "Test-Checksum：错误校验和 → 拒绝" } else { Fail "Test-Checksum：错误校验和应拒绝" }
    Remove-Item $manifestFile, $binaryFile -Force

    # Test-Checksum：manifest 中无此平台 → 跳过（返回 true）
    $manifestFile = New-TemporaryFile
    $binaryFile   = New-TemporaryFile
    '{"platforms":{"linux-x64":{"checksum":"abc","size":1}}}' | Set-Content $manifestFile
    $r = Test-Checksum -FilePath $binaryFile -ManifestFile $manifestFile -Platform "win32-x64"
    if ($r) { Pass "Test-Checksum：平台不存在 → 跳过校验" } else { Fail "Test-Checksum：平台不存在应跳过" }
    Remove-Item $manifestFile, $binaryFile -Force

    # Test-Checksum：无效 JSON → 跳过（返回 true）
    $manifestFile = New-TemporaryFile
    $binaryFile   = New-TemporaryFile
    "not json" | Set-Content $manifestFile
    $r = Test-Checksum -FilePath $binaryFile -ManifestFile $manifestFile -Platform "win32-x64"
    if ($r) { Pass "Test-Checksum：无效 JSON → 跳过校验" } else { Fail "Test-Checksum：无效 JSON 应跳过" }
    Remove-Item $manifestFile, $binaryFile -Force

    # GCS_BUCKET 常量格式正确
    if ($GCS_BUCKET -match '^https://storage\.googleapis\.com/') {
        Pass "GCS_BUCKET 常量格式正确"
    } else {
        Fail "GCS_BUCKET 常量格式错误: '$GCS_BUCKET'"
    }

    # Get-DownloadUrl 始终用 GithubMirror（不用 GCS）
    $global:GithubMirror   = "https://kkgithub.com"
    $global:SelectedMirror = "https://storage.googleapis.com/fake-gcs"
    $global:IsGCS          = $true
    $url = Get-DownloadUrl "/cc-switch/releases/download/v1.0/cc.msi"
    if ($url -match '^https://kkgithub\.com/') {
        Pass "Get-DownloadUrl IsGCS=true 时仍走 GithubMirror → $url"
    } else {
        Fail "Get-DownloadUrl IsGCS=true 时应走 GithubMirror，实际: '$url'"
    }

    # Invoke-DownloadMirror 以 GithubMirror 为首选（不含 GCS）
    $global:GithubMirror = "https://kkgithub.com"
    $tmpOut = Join-Path ([System.IO.Path]::GetTempPath()) "test_dl_$(Get-Random).bin"
    $dlOk = Invoke-DownloadMirror -Path "/nonexistent-path-for-test" -OutFile $tmpOut -Label "test" 2>$null
    Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue
    if (-not $dlOk) {
        Pass "Invoke-DownloadMirror：全部镜像失败时返回 false（不抛异常）"
    } else {
        Fail "Invoke-DownloadMirror：不存在的路径不应下载成功"
    }
}

# ── 第四层：真实安装测试（仅 Windows 环境）───────────────────────────────────
function Layer4 {
    Step "第四层：真实安装测试（仅 Windows）"

    if (-not $IsWindows) {
        Info "非 Windows 环境，跳过第四层"
        Info "在 Windows 上手动验证："
        Info "  1. powershell -ExecutionPolicy Bypass -File install.ps1"
        Info "  2. claude --version          # 验证安装成功"
        Info "  3. powershell -ExecutionPolicy Bypass -File uninstall.ps1"
        Info "  4. (winget 路径) winget list Anthropic.ClaudeCode  # 验证已移除"
        return
    }

    # 验证 claude 是否已安装（通过本脚本安装后运行）
    $iv = Get-InstalledVersion
    if ($iv -match '^\d+\.\d+\.\d+$') {
        Pass "claude 已安装 → v$iv"
    } else {
        Info "claude 未检测到（尚未安装或安装路径不在 PATH）"
    }

    # 验证 winget 检测逻辑
    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($wingetCmd) {
        $wingetList = & winget list --id Anthropic.ClaudeCode --exact 2>$null
        $isWinget = ($wingetList -match "Anthropic\.ClaudeCode")
        if ($isWinget) {
            Pass "winget 安装检测 → 已检测到 winget 安装"
        } else {
            Info "winget 可用，但 Claude Code 不是 winget 安装（原生安装路径）"
        }
    } else {
        Info "winget 不可用，跳过 winget 检测"
    }
}

# ── 主入口 ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== install.ps1 测试 ===  ProjectAILeap/claude-code-installer" -ForegroundColor Cyan
Write-Host ""

if (-not $Layers -or $Layers.Count -eq 0) { $Layers = @('1', '2', '3', '4') }

foreach ($l in $Layers) {
    switch ($l) {
        '1'     { Layer1 }
        '2'     { Layer2 }
        '3'     { Layer3 }
        '4'     { Layer4 }
        default { Write-Host "  未知层: $l，跳过" -ForegroundColor Yellow }
    }
}

Write-Host ""
Write-Host "━━━ 结果 ━━━" -ForegroundColor Cyan
if ($script:FAILURES -eq 0) {
    Write-Host "  全部通过" -ForegroundColor Green
    Write-Host ""
    exit 0
} else {
    Write-Host "  失败: $($script:FAILURES) 项" -ForegroundColor Red
    Write-Host ""
    exit 1
}
