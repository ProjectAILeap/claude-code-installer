@echo off
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

powershell -NoProfile -ExecutionPolicy Bypass -Command "& {$urls='https://ghfast.top/https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/uninstall.ps1','https://gh-proxy.com/https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/uninstall.ps1','https://mirror.ghproxy.com/https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/uninstall.ps1','https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/uninstall.ps1';$ok=$false;foreach($u in $urls){try{iex(irm $u -TimeoutSec 20 -UseBasicParsing);$ok=$true;break}catch{}};if(-not $ok){Write-Host '[ERROR] All mirrors failed.' -ForegroundColor Red;Write-Host 'Download uninstall.ps1 manually: https://github.com/ProjectAILeap/claude-code-installer' -ForegroundColor Yellow;exit 1}}"

set EXITCODE=%ERRORLEVEL%
if %EXITCODE% NEQ 0 (
    echo.
    echo  [ERROR] Uninstall failed. See messages above.
    echo.
)
pause
exit /b %EXITCODE%
