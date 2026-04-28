@echo off
REM Watch the sibling cf3d_input folder; analyse anything you drop in.
title CF3D Analyzer - Folder Watcher
set "ROOT=%~dp0.."
set "BASE=%~dp0..\.."
cd /d "%ROOT%"

if not exist ".venv\Scripts\activate.bat" (
    echo Run 1_install.bat first.
    pause
    exit /b 1
)
call ".venv\Scripts\activate.bat"

set "IN=%BASE%\cf3d_input"
set "OUT=%BASE%\cf3d_output"
if not exist "%IN%"  mkdir "%IN%"
if not exist "%OUT%" mkdir "%OUT%"

echo Watching:  %IN%
echo Output to: %OUT%
echo.
echo Drop .stp / .step / .dxf / .pdf / .png into the input folder.
echo Press Ctrl+C to stop.
echo.
cf3d watch "%IN%" --out "%OUT%" --ignore-existing
pause
