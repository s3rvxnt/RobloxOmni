@echo off
setlocal EnableDelayedExpansion
title Omni Setup ^& Recovery
color 0B

echo.
echo  ======================================================
echo    Omni
echo    Zero lag. Adaptive budgeting. Zero-trust security gate.
echo  ======================================================
echo.

if "%1"=="--safemode" goto :safemode
if "%1"=="-s" goto :safemode

echo  [1] Install / Update Omni (Default)
echo  [2] Enable Safe Mode (Bypass all autoexec scripts next launch)
echo  [3] Exit
echo.
set "choice=1"
set /p "choice=  Select an option [1-3] (Default 1): "
set "choice=!choice: =!"

if "!choice!"=="2" goto :safemode
if "!choice!"=="3" exit /b 0
goto :install

:install
echo.
if exist "%~dp0install.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main/install.ps1 | iex"
)
goto :end

:safemode
echo.
echo  [*] Enabling Safe Mode across all detected executors...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$detected = @((Get-Location).Path, $env:LOCALAPPDATA, $env:APPDATA, (Join-Path $env:USERPROFILE 'Desktop'), (Join-Path $env:USERPROFILE 'Downloads'), (Join-Path $env:USERPROFILE 'Documents'));" ^
    "foreach ($r in $detected) { if (-not (Test-Path $r)) { continue };" ^
    "  if ((Test-Path (Join-Path $r 'workspace')) -and ((Test-Path (Join-Path $r 'autoexec')) -or (Test-Path (Join-Path $r 'autoexe')))) {" ^
    "    $lock = Join-Path $r 'workspace\SAFE_MODE.lock';" ^
    "    Set-Content -Path $lock -Value 'true' -Force;" ^
    "    Write-Host ('  [OK] Safe Mode activated for ' + (Split-Path $r -Leaf)) -ForegroundColor Green;" ^
    "  }" ^
    "  Get-ChildItem -Path $r -Directory -ErrorAction SilentlyContinue | ForEach-Object {" ^
    "    if ((Test-Path (Join-Path $_.FullName 'workspace')) -and ((Test-Path (Join-Path $_.FullName 'autoexec')) -or (Test-Path (Join-Path $_.FullName 'autoexe')))) {" ^
    "      $lock = Join-Path $_.FullName 'workspace\SAFE_MODE.lock';" ^
    "      Set-Content -Path $lock -Value 'true' -Force;" ^
    "      Write-Host ('  [OK] Safe Mode activated for ' + $_.Name) -ForegroundColor Green;" ^
    "    }" ^
    "  }" ^
    "}"
echo.
echo  [OK] Safe Mode active! All third-party autoexec scripts
echo       will be bypassed next time you launch Roblox.
goto :end

:end
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo  [!] Setup encountered an issue or was cancelled.
)
echo.
pause
