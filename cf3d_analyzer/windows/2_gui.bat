@echo off
REM Double-click to launch the CF3D Analyzer desktop GUI.
title CF3D Analyzer - GUI
set "ROOT=%~dp0.."
cd /d "%ROOT%"

if not exist ".venv\Scripts\activate.bat" (
    echo Run 1_install.bat first.
    pause
    exit /b 1
)
call ".venv\Scripts\activate.bat"
cf3d gui
if errorlevel 1 (
    echo.
    echo *** GUI exited with an error. ***
    pause
)
