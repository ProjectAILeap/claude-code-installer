@echo off
chcp 65001 >nul
:: ============================================================================
::  Claude Code Uninstaller for Windows -- ProjectAILeap
::  https://github.com/ProjectAILeap/claude-code-installer
::
::  Bootstraps uninstall.ps1 from GitHub with mirror acceleration.
::  No local files required -- double-click to uninstall.
:: ============================================================================
setlocal

echo.
echo  Claude Code Uninstaller -- ProjectAILeap
echo  -----------------------------------------
echo.

echo  Fetching uninstaller script (trying mirrors)...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command "& {$urls=@('https://ghfast.top/https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/uninstall.ps1','https://gh-proxy.com/https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/uninstall.ps1','https://mirror.ghproxy.com/https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/uninstall.ps1','https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/uninstall.ps1');$c=$null;foreach($u in $urls){Write-Host('  '+$u) -ForegroundColor Gray;$j=Start-Job{irm $using:u -UseBasicParsing};if(Wait-Job $j -Timeout 15){if($j.State -eq 'Completed'){$c=Receive-Job $j -EA SilentlyContinue}};Remove-Job $j -Force -EA SilentlyContinue;if($c){Write-Host '  OK' -ForegroundColor Green;break}else{Write-Host '  Timeout or error, trying next...' -ForegroundColor Yellow}};if(-not $c){Write-Host '';Write-Host '[ERROR] All mirrors failed.' -ForegroundColor Red;Write-Host 'Download uninstall.ps1 manually: https://github.com/ProjectAILeap/claude-code-installer' -ForegroundColor Yellow;exit 1};if($c[0] -eq [char]0xFEFF){$c=$c.Substring(1)};iex $c}"

set EXITCODE=%ERRORLEVEL%
if %EXITCODE% NEQ 0 (
    echo.
    echo  [ERROR] Uninstall failed. See messages above.
    echo.
)
pause
exit /b %EXITCODE%
