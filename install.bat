@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set EXITCODE=%ERRORLEVEL%
if %EXITCODE% neq 0 (
    echo.
    echo Wystapil blad podczas dzialania instalatora (kod: %EXITCODE%).
    pause
)
exit /b %EXITCODE%
