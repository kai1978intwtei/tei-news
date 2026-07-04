@echo off
chcp 65001 >nul
title Sysclean - One-Click Scan
echo ================================================
echo   一鍵健檢（唯讀掃描，完成後自動打開報告）
echo ================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scan.ps1" -OpenReport
echo.
pause
