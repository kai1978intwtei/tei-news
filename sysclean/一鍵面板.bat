@echo off
chcp 65001 >nul
title Sysclean - Control Panel
echo ================================================
echo   一鍵清潔面板：啟動後瀏覽器會自動打開
echo   網址 http://localhost:8377 （關閉請按 Ctrl+C）
echo ================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0control-panel.ps1"
pause
