@echo off
chcp 65001 >nul 2>&1
setlocal
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo    Requesting administrator rights...
    echo    Please click "Yes" in the UAC prompt.
    echo.
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
title Laptop Cleaner
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0clean.ps1"
endlocal
