@echo off
:: ════════════════════════════════════════════════════════════════════════════
::  Claude Code Installer for Windows — ProjectAILeap
::  https://github.com/ProjectAILeap/claude-code-installer
::
::  双击此文件即可安装 / 升级 Claude Code（无需 npm）
::  Double-click to install or upgrade Claude Code (no npm required)
:: ════════════════════════════════════════════════════════════════════════════
setlocal

:: ── Check PowerShell ────────────────────────────────────────────────────────
for /f "tokens=*" %%v in ('powershell -NoProfile -Command "$PSVersionTable.PSVersion.Major" 2^>nul') do set PS_MAJOR=%%v
if "%PS_MAJOR%"=="" (
    echo [ERROR] PowerShell not found. Please install PowerShell 5.1 or later.
    echo         Download: https://github.com/PowerShell/PowerShell/releases
    pause
    exit /b 1
)
if %PS_MAJOR% LSS 5 (
    echo [ERROR] PowerShell %PS_MAJOR% detected. Version 5.1+ required.
    pause
    exit /b 1
)

:: ── Run installer ───────────────────────────────────────────────────────────
echo.
echo  Claude Code Installer - ProjectAILeap
echo  ─────────────────────────────────────
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set EXITCODE=%ERRORLEVEL%

if %EXITCODE% NEQ 0 (
    echo.
    echo [ERROR] Installation failed with exit code %EXITCODE%.
    echo         Check the error messages above for details.
    echo.
    pause
    exit /b %EXITCODE%
)

pause
exit /b 0
