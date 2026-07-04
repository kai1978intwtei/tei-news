@echo off
chcp 65001 >nul
title Sysclean - Install
echo ================================================
echo   sysclean 一鍵安裝：桌面按鈕 + 每週保養 +
echo   AI 橋接器 + Claude Code 檢查 + 第一次健檢
echo ================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
pause
