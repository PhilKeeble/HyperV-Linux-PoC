@echo off
setlocal EnableDelayedExpansion

set LOGFILE=C:\Windows\Temp\BaseImageSetup.log
set SCRIPTDIR=C:\BaseImageSetup
set PSSCRIPT=%SCRIPTDIR%\Configure-BaseImage.ps1

echo ============================================================ >> "%LOGFILE%"
echo  Base Image Setup - SetupComplete.cmd >> "%LOGFILE%"
echo  Started: %DATE% %TIME% >> "%LOGFILE%"
echo ============================================================ >> "%LOGFILE%"

echo [%DATE% %TIME%] SetupComplete.cmd started
echo [%DATE% %TIME%] SetupComplete.cmd started >> "%LOGFILE%"
echo [%DATE% %TIME%] Script directory: %SCRIPTDIR% >> "%LOGFILE%"
echo [%DATE% %TIME%] Log file: %LOGFILE% >> "%LOGFILE%"

:: Set execution policy so we can run our PowerShell script
echo [%DATE% %TIME%] Setting PowerShell execution policy to Bypass... >> "%LOGFILE%"
PowerShell.exe -NoProfile -NonInteractive -Command "Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force" >> "%LOGFILE%" 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo [%DATE% %TIME%] WARNING: Set-ExecutionPolicy returned non-zero. Continuing anyway. >> "%LOGFILE%"
)

:: Verify the configuration script is present
if not exist "%PSSCRIPT%" (
    echo [%DATE% %TIME%] FATAL ERROR: Configure-BaseImage.ps1 not found at %PSSCRIPT% >> "%LOGFILE%"
    echo [%DATE% %TIME%] Contents of %SCRIPTDIR%: >> "%LOGFILE%"
    dir "%SCRIPTDIR%" >> "%LOGFILE%" 2>&1
    exit /b 1
)

echo [%DATE% %TIME%] Configure-BaseImage.ps1 found. Launching... >> "%LOGFILE%"

:: Run the configuration script. Output goes to log.
PowerShell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%PSSCRIPT%" >> "%LOGFILE%" 2>&1
set EXITCODE=%ERRORLEVEL%

echo [%DATE% %TIME%] Configure-BaseImage.ps1 finished with exit code: %EXITCODE% >> "%LOGFILE%"

if %EXITCODE% NEQ 0 (
    echo [%DATE% %TIME%] ERROR: Configuration script failed. See %LOGFILE% for details.
    echo [%DATE% %TIME%] ERROR: Configuration script failed. Exit code: %EXITCODE% >> "%LOGFILE%"
    exit /b %EXITCODE%
)

echo [%DATE% %TIME%] SetupComplete.cmd completed successfully. >> "%LOGFILE%"
endlocal
exit /b 0
