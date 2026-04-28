@echo off
REM ============================================================
REM   CF3D Studio - launch the modern web UI in your browser.
REM   Double-click this file.  Browser opens automatically at
REM   http://127.0.0.1:8765
REM ============================================================
title CF3D Studio
set "ROOT=%~dp0.."
cd /d "%ROOT%"

if not exist ".venv\Scripts\activate.bat" (
    echo Run 1_install.bat first.
    pause
    exit /b 1
)
call ".venv\Scripts\activate.bat"
echo.
echo Opening CF3D Studio at http://127.0.0.1:8765
echo Close this window or press Ctrl+C to stop.
echo.
cf3d serve
pause
