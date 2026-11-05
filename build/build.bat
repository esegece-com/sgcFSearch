@echo off
rem ***************************************************************************
rem  sgcFSearch: build every project under App\, CLI\ and Tests\ for Win64.
rem
rem  usage: build.bat [Debug|Release]   (default Debug)
rem  Each project goes through _msb.bat (global lock, log in build\logs).
rem  Exit code: 0 = all built, 1 = at least one project failed.
rem ***************************************************************************
setlocal EnableExtensions
set "CFG=%~1"
if "%CFG%"=="" set "CFG=Debug"
for %%R in ("%~dp0..") do set "ROOT=%%~fR"
set /a OKC=0
set /a FAILC=0
call :scan "%ROOT%\App"
call :scan "%ROOT%\CLI"
call :scan "%ROOT%\Tests"
set /a TOTAL=OKC+FAILC
echo ---- build %CFG% Win64: %TOTAL% projects, %OKC% ok, %FAILC% failed
if %FAILC% GTR 0 exit /b 1
exit /b 0

rem ---- build every .dproj below %1 (FOR /R needs a plain path, not a FOR variable)
:scan
if not exist "%~1" exit /b 0
for /r "%~1" %%P in (*.dproj) do call :one "%%P"
exit /b 0

:one
call "%~dp0_msb.bat" "%~1" Win64 %CFG%
if errorlevel 1 (set /a FAILC+=1) else (set /a OKC+=1)
exit /b 0
