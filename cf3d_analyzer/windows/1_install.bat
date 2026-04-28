@echo off
REM ============================================================
REM   CF3D Analyzer - one-click installer for Windows
REM   Double-click this file once, the first time you set up.
REM ============================================================
setlocal EnableDelayedExpansion
title CF3D Analyzer - Installer

set "ROOT=%~dp0.."
cd /d "%ROOT%" || goto :err

echo.
echo === [1/4] Checking Python ===
where python >nul 2>nul
if errorlevel 1 (
    echo.
    echo  Python is not on PATH.
    echo  Download from https://www.python.org/downloads/
    echo  IMPORTANT: tick "Add Python to PATH" while installing.
    pause
    exit /b 1
)
python --version

echo.
echo === [2/4] Creating virtual environment ===
if not exist ".venv\Scripts\activate.bat" (
    python -m venv .venv || goto :err
) else (
    echo .venv already exists - skipping.
)

echo.
echo === [3/4] Installing CF3D Analyzer + extras ===
call ".venv\Scripts\activate.bat" || goto :err
python -m pip install --upgrade pip setuptools wheel || goto :err
pip install -e .[all] || goto :err

echo.
echo === [4/4] Creating Desktop folders ===
if not exist "%USERPROFILE%\Desktop\cf3d_input"  mkdir "%USERPROFILE%\Desktop\cf3d_input"
if not exist "%USERPROFILE%\Desktop\cf3d_output" mkdir "%USERPROFILE%\Desktop\cf3d_output"

echo.
echo ============================================================
echo   Install OK.
echo.
echo   Drop your .stp / .step / .dxf / .pdf into:
echo     %USERPROFILE%\Desktop\cf3d_input
echo.
echo   Reports will appear in:
echo     %USERPROFILE%\Desktop\cf3d_output
echo.
echo   Next, double-click:
echo     2_gui.bat       - desktop GUI
echo     3_analyze.bat   - drag a drawing onto this file
echo     4_watch.bat     - auto-analyse new files in cf3d_input
echo ============================================================
pause
exit /b 0

:err
echo.
echo *** Install failed. Read the messages above. ***
pause
exit /b 1
