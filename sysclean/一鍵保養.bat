@echo off
chcp 65001 >nul
title Sysclean - One-Click Tune
echo ================================================
echo   一鍵安全保養（零風險：暫存/瀏覽器快取/DNS）
echo ================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0quick-tune.ps1"
echo.
pause
