@echo off
REM Quick-open the sibling input/output folders in Explorer.
set "BASE=%~dp0..\.."
set "IN=%BASE%\cf3d_input"
set "OUT=%BASE%\cf3d_output"
if not exist "%IN%"  mkdir "%IN%"
if not exist "%OUT%" mkdir "%OUT%"
start "" "%IN%"
start "" "%OUT%"
