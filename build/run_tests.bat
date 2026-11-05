@echo off
rem ***************************************************************************
rem  sgcFSearch: run every bin\Win64\Debug\Test_*.exe.
rem
rem  Each test's output goes to build\logs\test_<name>.log; one [PASS] or
rem  [FAIL] line is printed per test, then a summary.
rem  Exit code: 0 = all passed, 1 = at least one failed (or none found).
rem ***************************************************************************
setlocal EnableExtensions EnableDelayedExpansion
set "BIN=%~dp0..\bin\Win64\Debug"
set "LOGDIR=%~dp0logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"
set /a PASSC=0
set /a FAILC=0
if not exist "%BIN%\Test_*.exe" (
  echo No test executables in %BIN%
  exit /b 1
)
for %%T in ("%BIN%\Test_*.exe") do (
  set "TLOG=%LOGDIR%\test_%%~nT.log"
  "%%~fT" > "!TLOG!" 2>&1 < nul
  if errorlevel 1 (
    set /a FAILC+=1
    echo [FAIL] %%~nT ^(log: !TLOG!^)
  ) else (
    set /a PASSC+=1
    echo [PASS] %%~nT
  )
)
set /a TOTAL=PASSC+FAILC
echo ---- tests: %TOTAL% run, %PASSC% passed, %FAILC% failed
if %FAILC% GTR 0 exit /b 1
exit /b 0
