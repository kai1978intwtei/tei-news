@echo off
REM Run the smoke tests to confirm the install is healthy.
title CF3D Analyzer - Tests
set "ROOT=%~dp0.."
cd /d "%ROOT%"
if not exist ".venv\Scripts\activate.bat" (
    echo Run 1_install.bat first.
    pause
    exit /b 1
)
call ".venv\Scripts\activate.bat"
python tests\test_pipeline.py
pause
