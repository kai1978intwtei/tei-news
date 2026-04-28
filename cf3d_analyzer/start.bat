@echo off
REM CF3D Analyzer launcher (Windows).
setlocal
cd /d "%~dp0\.."
python -m cf3d_analyzer %*
endlocal
