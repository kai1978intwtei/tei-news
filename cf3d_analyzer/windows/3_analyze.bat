@echo off
REM ============================================================
REM   Analyse one drawing (portable - works wherever the folder
REM   is moved).  Drag a .stp / .step / .dxf / .pdf onto this
REM   file in Explorer, or double-click and type a path.
REM ============================================================
setlocal EnableDelayedExpansion
title CF3D Analyzer - Analyse drawing
set "ROOT=%~dp0.."
set "BASE=%~dp0..\.."
cd /d "%ROOT%"

if not exist ".venv\Scripts\activate.bat" (
    echo Run 1_install.bat first.
    pause
    exit /b 1
)
call ".venv\Scripts\activate.bat"

set "DRAWING=%~1"
if "%DRAWING%"=="" (
    set /p DRAWING=Path to drawing (.stp/.step/.dxf/.pdf):
)
if "%DRAWING%"=="" (
    echo No drawing given.
    pause
    exit /b 1
)
if not exist "%DRAWING%" (
    echo File not found: %DRAWING%
    pause
    exit /b 1
)

set "OUT=%BASE%\cf3d_output"
if not exist "%OUT%" mkdir "%OUT%"

echo.
echo Analysing: %DRAWING%
echo Output to: %OUT%
echo.

cf3d analyze "%DRAWING%" ^
     --annual-volume 500 ^
     --quality A ^
     --application structural ^
     --matrix epoxy ^
     --out "%OUT%"

if errorlevel 1 (
    echo.
    echo *** Analysis failed. ***
    pause
    exit /b 1
)

for %%F in ("%DRAWING%") do set "STEM=%%~nF"
if exist "%OUT%\!STEM!.report.html" (
    start "" "%OUT%\!STEM!.report.html"
)
echo.
echo Report ready in %OUT%
pause
