@echo off
rem ===========================================================================
rem  run_all.bat - double-click entry for the gtableViewer data rebuild.
rem
rem  What it does (see run_all.ps1 for details):
rem      rds\*.rds  ->  samples\*.json + samples\index.json
rem                   -> path check -> single-file preview.html
rem
rem  Keep this file ASCII only: cmd.exe reads .bat with the OEM code page, so
rem  non-ASCII text here becomes mojibake and can even break parsing.
rem
rem  Extra arguments are forwarded to run_all.ps1, for example:
rem      run_all.bat -Samples          rebuild the four sample .rds first
rem      run_all.bat -SkipPreview      stop before building preview.html
rem ===========================================================================
setlocal
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_all.ps1" %*
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (echo [OK] gtableViewer data rebuilt.) else (echo [FAIL] exit code %RC% - see the output above.)
echo.
pause
endlocal & exit /b %RC%
