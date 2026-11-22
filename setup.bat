@echo off
setlocal
title Flatscreen VR - Setup
cd /d "%~dp0"

echo ==========================================
echo   Flatscreen VR - first-time setup
echo ==========================================
echo.

rem ---------- 1. Find a usable Python (3.9 or newer) ----------
call :find_python
if defined PY goto :have_python

echo Python was not found. Installing Python 3.12 for your user account...
echo (no admin rights needed, this can take a few minutes)
echo.

rem Try winget first (built into Windows 10/11)
where winget >nul 2>&1
if errorlevel 1 goto :download_python
winget install -e --id Python.Python.3.12 --scope user --silent --accept-package-agreements --accept-source-agreements
call :find_python
if defined PY goto :have_python

:download_python
echo Downloading the installer from python.org...
set "PY_INSTALLER=%TEMP%\python-3.12-installer.exe"
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; Invoke-WebRequest -Uri 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe' -OutFile '%PY_INSTALLER%'"
if not exist "%PY_INSTALLER%" goto :python_failed
echo Running the Python installer...
"%PY_INSTALLER%" /quiet InstallAllUsers=0 PrependPath=1 Include_launcher=1 Include_test=0
del "%PY_INSTALLER%" >nul 2>&1
call :find_python
if defined PY goto :have_python

:python_failed
echo.
echo ERROR: Could not install Python automatically.
echo Please install it from https://www.python.org/downloads/
echo IMPORTANT: tick "Add python.exe to PATH" in the installer, then run setup.bat again.
echo.
pause
exit /b 1

:have_python
echo Using Python: %PY%
%PY% --version
echo.

rem ---------- 2. Install the libraries ----------
echo Installing libraries (openvr, numpy, scipy)...
%PY% -m pip install --upgrade pip --quiet --disable-pip-version-check
%PY% -m pip install -r requirements.txt --disable-pip-version-check
if errorlevel 1 goto :pip_failed

rem ---------- 3. Quick check that everything imports ----------
%PY% -c "import openvr, numpy, scipy.spatial.transform; print('All libraries OK')"
if errorlevel 1 goto :pip_failed

echo.
echo ==========================================
echo   Setup complete!
echo   Now run run_flatscreen.bat - it starts SteamVR and the controls
echo ==========================================
echo.
pause
exit /b 0

:pip_failed
echo.
echo ERROR: Installing the libraries failed. Check your internet connection and run setup.bat again.
echo If it keeps failing, open an issue on GitHub and paste everything shown in this window.
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
