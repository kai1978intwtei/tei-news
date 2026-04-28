@echo off
REM Quick-open the Desktop input/output folders in Explorer.
set "IN=%USERPROFILE%\Desktop\cf3d_input"
set "OUT=%USERPROFILE%\Desktop\cf3d_output"
if not exist "%IN%"  mkdir "%IN%"
if not exist "%OUT%" mkdir "%OUT%"
start "" "%IN%"
start "" "%OUT%"
