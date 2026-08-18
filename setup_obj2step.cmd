@echo off
REM One-time setup for the OBJ -> STEP converter. Double-click me, or run from a terminal.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_obj2step.ps1" %*
echo.
pause
