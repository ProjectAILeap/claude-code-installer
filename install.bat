@echo off
chcp 65001 >nul
:: ============================================================================
::  Claude Code Installer for Windows -- ProjectAILeap
::  https://github.com/ProjectAILeap/claude-code-installer
:: ============================================================================
setlocal

echo.
echo  Claude Code Installer -- ProjectAILeap
echo  ---------------------------------------
echo.
echo  Testing mirror speeds and downloading installer script...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command "& {$mirrors=@('https://ghfast.top/https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/install.ps1','https://gh-proxy.com/https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/install.ps1','https://mirror.ghproxy.com/https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/install.ps1','https://raw.kkgithub.com/ProjectAILeap/claude-code-installer/main/install.ps1','https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/install.ps1'); Write-Host '  Testing mirrors...' -ForegroundColor Cyan; $jobs=@(); foreach($u in $mirrors){$jobs+=Start-Job -ScriptBlock {param($url); $sw=[System.Diagnostics.Stopwatch]::StartNew(); try{Invoke-WebRequest -Uri $url -Method Head -TimeoutSec 8 -UseBasicParsing -ErrorAction Stop|Out-Null; $sw.Stop(); [PSCustomObject]@{Url=$url;Ms=$sw.ElapsedMilliseconds;Ok=$true}}catch{$sw.Stop(); [PSCustomObject]@{Url=$url;Ms=99999;Ok=$false}}} -ArgumentList $u}; $jobs|Wait-Job -Timeout 10|Out-Null; $results=$jobs|ForEach-Object{if($_.State -eq 'Completed'){Receive-Job $_ -ErrorAction SilentlyContinue}}|Where-Object{$_.Ok}|Sort-Object Ms; $jobs|Remove-Job -Force -ErrorAction SilentlyContinue; foreach($r in $results){$tag=if($r.Url -match 'raw\.githubusercontent\.com/Pro'){'(direct)'}else{$r.Url -replace 'https://([^/]+)/.*','$1'}; Write-Host ('  {0,-45} {1,6} ms' -f $tag,$r.Ms) -ForegroundColor Gray}; $content=$null; if($results -and $results.Count -gt 0){$fastest=$results[0]; Write-Host ''; Write-Host ('  Fastest: {0} ({1} ms)' -f ($fastest.Url -replace 'https://([^/]+)/.*','$1'),$fastest.Ms) -ForegroundColor Green; foreach($r in $results){try{$content=Invoke-RestMethod -Uri $r.Url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop; Write-Host '  Download OK' -ForegroundColor Green; break}catch{Write-Host ('  Download failed from {0}, trying next...' -f ($r.Url -replace 'https://([^/]+)/.*','$1')) -ForegroundColor Yellow}}}; if(-not $content){Write-Host '  Speed test found no reachable mirror, trying sequential fallback...' -ForegroundColor Yellow; foreach($u in $mirrors){Write-Host ('  '+$u) -ForegroundColor Gray; try{$content=Invoke-RestMethod -Uri $u -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop; Write-Host '  OK' -ForegroundColor Green; break}catch{Write-Host '  Failed, trying next...' -ForegroundColor Yellow}}}; if(-not $content){Write-Host ''; Write-Host '[ERROR] All mirrors failed.' -ForegroundColor Red; Write-Host 'Download install.ps1 manually: https://github.com/ProjectAILeap/claude-code-installer' -ForegroundColor Yellow; exit 1}; if($content[0] -eq [char]0xFEFF){$content=$content.Substring(1)}; Invoke-Expression $content}"

set EXITCODE=%ERRORLEVEL%
if %EXITCODE% NEQ 0 (
    echo.
    echo  [ERROR] Installation failed. See messages above.
    echo.
)
pause
exit /b %EXITCODE%
