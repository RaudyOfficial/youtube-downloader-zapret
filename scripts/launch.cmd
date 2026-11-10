@echo off
chcp 65001 >nul
set "PS_SCRIPT=%~dp0downloader.ps1"
where pwsh >nul 2>nul
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%"
)
echo.
pause
