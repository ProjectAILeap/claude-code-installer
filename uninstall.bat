@echo off
:: ════════════════════════════════════════════════════════════════════════════
::  Claude Code Uninstaller for Windows — ProjectAILeap
::  https://github.com/ProjectAILeap/claude-code-installer
::
::  双击此文件卸载 Claude Code
::  Double-click to uninstall Claude Code
:: ════════════════════════════════════════════════════════════════════════════
setlocal

for /f "tokens=*" %%v in ('powershell -NoProfile -Command "$PSVersionTable.PSVersion.Major" 2^>nul') do set PS_MAJOR=%%v
if "%PS_MAJOR%"=="" (
    echo [ERROR] PowerShell not found.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
set EXITCODE=%ERRORLEVEL%

if %EXITCODE% NEQ 0 (
    echo.
    echo [ERROR] Uninstall failed with exit code %EXITCODE%.
    pause
    exit /b %EXITCODE%
)

pause
exit /b 0
