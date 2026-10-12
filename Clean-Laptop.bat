@echo off
rem ============================================================
rem  Laptop Cleaner - English UI launcher
rem  The script itself asks for administrator rights (optional)
rem  and falls back to user-level cleanup if you decline.
rem ============================================================
chcp 65001 >nul 2>&1
title Laptop Cleaner
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0clean.ps1"
if %errorlevel% neq 0 (
    echo.
    echo    The tool exited with an error. If nothing appeared,
    echo    right-click this file and choose "Run as administrator".
    echo.
    pause
)
