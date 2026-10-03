@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_PATH=%SCRIPT_DIR%WsusManager.ps1"

rem Prefer the portable exe when it sits next to this launcher.
if exist "%SCRIPT_DIR%WsusManager.exe" (
    "%SCRIPT_DIR%WsusManager.exe" %*
    exit /b %ERRORLEVEL%
)

rem The WSUS administration API is .NET Framework only, so use Windows PowerShell 5.1.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" %*
exit /b %ERRORLEVEL%
