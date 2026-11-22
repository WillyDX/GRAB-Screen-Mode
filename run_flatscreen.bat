@echo off
setlocal
title Flatscreen VR - Controls
cd /d "%~dp0"

call :find_python
if not defined PY goto :need_setup
%PY% -c "import openvr, numpy, scipy" >nul 2>&1
if errorlevel 1 goto :need_setup

echo Starting SteamVR without a headset (accept the admin prompt)...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_novr.ps1" -NoPause
if errorlevel 1 goto :steamvr_failed

%PY% flatscreen_vr.py
exit /b %errorlevel%

:steamvr_failed
echo.
echo SteamVR setup didn't finish - see the setup window for the error.
echo.
pause
exit /b 1

:need_setup
echo Python or the required libraries aren't installed yet.
echo Please run setup.bat first, then try again.
echo.
pause
exit /b 1


rem ---------- Helper: sets PY to a working Python 3.9+ command, or leaves it empty ----------
:find_python
set "PY="
set "CHECK=import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)"

rem The py launcher, from PATH or from the default per-user install location
py -3 -c "%CHECK%" >nul 2>&1
if not errorlevel 1 set "PY=py -3"& goto :eof
if exist "%LocalAppData%\Programs\Python\Launcher\py.exe" (
    "%LocalAppData%\Programs\Python\Launcher\py.exe" -3 -c "%CHECK%" >nul 2>&1
    if not errorlevel 1 set "PY="%LocalAppData%\Programs\Python\Launcher\py.exe" -3"& goto :eof
)

rem python on PATH (the Microsoft Store placeholder fails this check, which is what we want)
python -c "%CHECK%" >nul 2>&1
if not errorlevel 1 set "PY=python"& goto :eof

rem A fresh per-user install that isn't on this window's PATH yet
for %%V in (313 312 311 310) do (
    if exist "%LocalAppData%\Programs\Python\Python%%V\python.exe" (
        set "PY="%LocalAppData%\Programs\Python\Python%%V\python.exe""
        goto :eof
    )
)
goto :eof
