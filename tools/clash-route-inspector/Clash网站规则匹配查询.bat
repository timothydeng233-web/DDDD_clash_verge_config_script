@echo off
chcp 65001 >nul
title Clash URL Route Inspector
cd /d "%~dp0"

set "PYEXE="

rem --- 1) official launcher, only present with a real Python install ---
py --version >nul 2>nul
if not errorlevel 1 set "PYEXE=py.exe"

rem --- 2) python.exe on PATH, must really report a version ---
rem     (the WindowsApps stub fails this check)
if not defined PYEXE (
  python --version >nul 2>nul
  if not errorlevel 1 set "PYEXE=python.exe"
)

rem --- 3) well-known install locations ---
if not defined PYEXE if exist "%LOCALAPPDATA%\Programs\Python\Launcher\py.exe" set "PYEXE=%LOCALAPPDATA%\Programs\Python\Launcher\py.exe"

if not defined PYEXE (
  echo.
  echo   [ERROR] No usable Python found.
  echo   Please install Python 3.10 or newer and tick "Add Python to PATH".
  echo   https://www.python.org/downloads/
  echo.
  pause
  exit /b 1
)

echo.
echo   Interpreter : %PYEXE%
echo   Starting local console, please wait...
echo.

"%PYEXE%" app.py %*
set "RC=%errorlevel%"

echo.
if not "%RC%"=="0" echo   [ERROR] app.py exited with code %RC%
echo   Service stopped.
echo.
pause
