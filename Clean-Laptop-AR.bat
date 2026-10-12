@echo off
rem ============================================================
rem  أداة تنظيف اللابتوب - مشغّل الواجهة العربية
rem  السكريبت نفسه يطلب صلاحيات المدير (اختياري)
rem  ويكمل التنظيف العادي لو رفضت الطلب
rem ============================================================
chcp 65001 >nul 2>&1
title Laptop Cleaner - Arabic
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0clean-ar.ps1"
if %errorlevel% neq 0 (
    echo.
    echo    حدث خطأ. لو مفيش حاجة ظهرت،
    echo    اعمل كليك يمين على الملف واختر "Run as administrator".
    echo.
    pause
)
