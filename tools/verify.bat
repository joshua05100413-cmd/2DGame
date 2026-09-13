@echo off
REM ============================================================================
REM  Headless verification harness for the TowDownGame -> multiplayer project.
REM
REM  Runs the game headless and FAILS on any engine/script error.
REM
REM  WHY A .bat AND NOT A .ps1
REM    * PowerShell script execution is disabled on this machine, and nested
REM      `powershell -File` runs do not reliably inherit a redirected APPDATA,
REM      which produced false PASS results.
REM    * This batch file sets APPDATA itself, so the environment is always right.
REM
REM  SANDBOX QUIRKS HANDLED HERE
REM    1. Godot needs a writable user:// directory. The default
REM       (%APPDATA%\Godot\app_userdata\<project>) is NOT writable, which makes
REM       Godot die with "signal 11" right after:
REM           ERROR: Could not create directory: 'user://logs'
REM       -> APPDATA is redirected into the workspace below.
REM    2. --log-file swallows stdout, and stdout cannot be captured through a
REM       pipeline here, so we audit Godot's own user://logs/godot.log.
REM
REM  USAGE
REM    tools\verify.bat                  boot main scene via driver, 300 frames
REM    tools\verify.bat 900              ... 900 frames
REM    tools\verify.bat 60 selftest      must FAIL (proves the audit works)
REM    tools\verify.bat 300 game         run the real main scene
REM    tools\verify.bat 0   import       (re)import assets and report errors
REM ============================================================================
setlocal EnableDelayedExpansion

set "PROJECT_DIR=%~dp0.."
pushd "%PROJECT_DIR%"
set "PROJECT_DIR=%CD%"
popd

set "GODOT_EXE=D:\Godot\Godot_v4.4-stable_win64.exe\Godot_v4.4-stable_win64.exe"
if not exist "%GODOT_EXE%" (
    echo RESULT: FAIL - Godot executable not found: %GODOT_EXE%
    exit /b 2
)

REM Quirk 1: writable user:// root inside the workspace.
set "APPDATA=%PROJECT_DIR%\_userdata"
if not exist "%APPDATA%" mkdir "%APPDATA%"

set "LOG_DIR=%APPDATA%\Godot\app_userdata\Don't Stop\logs"
if exist "%LOG_DIR%" del /q "%LOG_DIR%\*.log" >nul 2>&1

set "FRAMES=%~1"
if "%FRAMES%"=="" set "FRAMES=300"
set "MODE=%~2"
if "%MODE%"=="" set "MODE=driver"

if /i "%MODE%"=="import" (
    set "GODOT_ARGS=--headless --path "%PROJECT_DIR%" --import"
    goto :run
)
if /i "%MODE%"=="game" (
    set "GODOT_ARGS=--headless --path "%PROJECT_DIR%" --quit-after %FRAMES%"
    goto :run
)

REM default: driver mode (the driver quits itself, so no --quit-after)
set "DRIVER_ARGS=--frames=%FRAMES%"
if /i "%MODE%"=="selftest" set "DRIVER_ARGS=%DRIVER_ARGS% --fail-test"
set "GODOT_ARGS=--headless --path "%PROJECT_DIR%" --script res://tools/headless_verify.gd -- %DRIVER_ARGS%"

:run
echo ==^> godot %GODOT_ARGS%
"%GODOT_EXE%" %GODOT_ARGS%

REM --- read the log (Godot flushes it asynchronously; wait for it) -------------
set "LOG_FILE="
for /l %%i in (1,1,40) do (
    if not defined LOG_FILE (
        for /f "delims=" %%f in ('dir /b /o-s "%LOG_DIR%\*.log" 2^>nul') do (
            if not defined LOG_FILE set "LOG_FILE=%LOG_DIR%\%%f"
        )
        if not defined LOG_FILE ping -n 1 -w 100 127.0.0.1 >nul
    )
)

echo.
if not defined LOG_FILE (
    echo RESULT: FAIL - Godot produced no log file ^(engine crashed at startup^)
    exit /b 1
)

echo --- %LOG_FILE% ---
type "%LOG_FILE%"
echo --- end log ---

REM --- audit ------------------------------------------------------------------
REM Known-benign lines that must NOT fail the build. Filtering happens by
REM dropping them before the fatal patterns are searched for.
REM   * root certificate store    -> sandbox cannot read the Windows cert store
REM   * ObjectDB / resource leaks -> Godot's usual at-exit chatter
REM   * shader sampler condition  -> pre-existing, non-fatal engine condition
set "FILTERED=%TEMP%\tdg_filtered.log"
findstr /v /c:"Failed to read the root certificate store" /c:"get_system_ca_certificates" /c:"os_windows.cpp:2289" /c:"ObjectDB instances leaked" /c:"resources still in use at exit" /c:"custom_samplers" "%LOG_FILE%" > "%FILTERED%"

set "FOUND=0"
call :check "SCRIPT ERROR"
call :check "Parse Error"
call :check "CrashHandlerException"
call :check "ERROR:"

echo.
if "!FOUND!"=="1" (
    echo RESULT: FAIL - errors found in log
    exit /b 1
)

echo RESULT: PASS - no script/engine errors
exit /b 0

:check
findstr /c:%1 "%FILTERED%" >nul 2>&1
if !ERRORLEVEL! EQU 0 (
    echo.
    echo MATCHED %~1
    findstr /c:%1 "%FILTERED%"
    set "FOUND=1"
)
exit /b 0
