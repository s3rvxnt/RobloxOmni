@echo off
setlocal
title Omni Setup
color 0B

echo.
echo  ======================================================
echo    Omni
echo    Zero lag. Adaptive budgeting. Silent auto-updates.
echo  ======================================================
echo.

if exist "%~dp0install.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/s3rvxnt/RobloxOmni/main/install.ps1 | iex"
)

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo  [!] Setup encountered an issue or was cancelled.
)

echo.
pause
