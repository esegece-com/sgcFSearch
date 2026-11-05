@echo off
rem ***************************************************************************
rem  sgcFSearch: build one Delphi project with msbuild (internal helper).
rem
rem  usage: _msb.bat <project.dproj> <Win64> [Debug|Release]   (Config = Debug)
rem  The full msbuild log goes to build\logs\<project>_<Platform>_<Config>.log.
rem  Only the error, fatal and warning lines are printed, then one result line.
rem  A global lock (build\logs\.lock) serializes compiles of parallel agents;
rem  a lock older than 10 minutes is removed as stale.
rem  Exit code: 0 = ok, 1 = build failed, 2 = usage error.
rem ***************************************************************************
setlocal EnableExtensions
set "PROJ=%~f1"
set "PLAT=%~2"
set "CFG=%~3"
if "%CFG%"=="" set "CFG=Debug"
if "%~1"=="" exit /b 2
if "%~2"=="" exit /b 2
if not exist "%PROJ%" (
  echo Project not found: %~1
  exit /b 2
)
set "BDSVARS=C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat"
if not exist "%BDSVARS%" (
  echo rsvars.bat not found: "%BDSVARS%"
  exit /b 2
)
set "LOGDIR=%~dp0logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"
set "LOCK=%LOGDIR%\.lock"
set "NAME=%~n1"
set "LOG=%LOGDIR%\%NAME%_%PLAT%_%CFG%.log"

rem ---- acquire the global compile lock -------------------------------------
:lock
mkdir "%LOCK%" 2>nul && goto locked
powershell -NoProfile -Command "$d=Get-Item -LiteralPath '%LOCK%' -ErrorAction SilentlyContinue; if($d -and $d.CreationTime -lt (Get-Date).AddMinutes(-10)){exit 1}else{exit 0}" >nul 2>&1
if errorlevel 1 (
  echo [LOCK]   removing stale lock %LOCK%
  rmdir "%LOCK%" 2>nul
  goto lock
)
ping -n 3 127.0.0.1 >nul
goto lock
:locked

call "%BDSVARS%" >nul
msbuild "%PROJ%" /t:Build /p:Config=%CFG% /p:Platform=%PLAT% /v:minimal /nologo /fl "/flp:logfile=%LOG%;verbosity=normal" >nul 2>&1
set "RC=%ERRORLEVEL%"
rmdir "%LOCK%" 2>nul

findstr /I /R /C:"^[^ ].*: error [A-Z][0-9]" /C:"^[^ ].*: fatal [A-Z][0-9]" /C:"^[^ ].*: warning [A-Z][0-9]" /C:"^[^ ].*error MSB" /C:"^[^ ].*warning MSB" "%LOG%" 2>nul
if "%RC%"=="0" (
  echo [OK]     %NAME% %PLAT% %CFG%
  exit /b 0
)
echo [FAILED] %NAME% %PLAT% %CFG% ^(log: %LOG%^)
exit /b 1
