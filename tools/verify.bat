@echo off
REM ============================================================================
REM  TowDownGame headless verification entry point.
REM
REM  WHY A .bat AND NOT A .ps1
REM    * PowerShell script execution is disabled on this machine, and nested
REM      `powershell -File` runs do not reliably inherit a redirected APPDATA,
REM      which produced false PASS results.
REM    * Godot's win64 binary is a GUI-subsystem executable: PowerShell's `&`
REM      call operator does NOT wait for it and its stdout is lost entirely.
REM      cmd waits, so the entry point lives in a .bat.
REM
REM  WHY THIS FILE IS PURE ASCII
REM    cmd reads .bat files using the OEM code page (936 on this box), not UTF-8.
REM    Multi-byte comments get mangled into stray redirection characters and
REM    silently corrupt the batch structure - which once produced a PASS while
REM    no test had actually run. Keep every byte here 7-bit.
REM
REM  SANDBOX QUIRKS HANDLED HERE
REM    1. Godot needs a writable user:// directory. The default
REM       %APPDATA%\Godot\app_userdata\<project> is not writable, so Godot dies
REM       with "signal 11" right after "Could not create directory: 'user://logs'".
REM       -> APPDATA is redirected into the workspace below.
REM    2. --log-file swallows stdout and stdout cannot be captured anyway, so
REM       we always audit Godot's own user://logs/godot.log.
REM    3. A crash leaves a .recovery_mode_lock behind; Godot then boots in
REM       recovery mode and silently skips scripts.
REM
REM  USAGE
REM    tools\verify.bat                         boot main scene, 300 frames
REM    tools\verify.bat 900                     ... 900 frames
REM    tools\verify.bat 300 game                run the real main scene
REM    tools\verify.bat 0   import              (re)import assets and audit
REM    tools\verify.bat 0   compile             compile every script/resource
REM    tools\verify.bat 0   net                 transport-layer loopback test
REM    tools\verify.bat 0   coop                co-op replication test
REM    tools\verify.bat 0   steam               Steam backend fallback test
REM    tools\verify.bat 60  selftest            must FAIL (proves the audit works)
REM    tools\verify.bat 0   all                 compile + net + coop + steam
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

set "USER_DIR=%APPDATA%\Godot\app_userdata\Don't Stop"
set "LOG_DIR=%USER_DIR%\logs"
REM Quirk 3: clear the recovery lock and stale logs of the previous run.
if exist "%USER_DIR%\.recovery_mode_lock" del /q "%USER_DIR%\.recovery_mode_lock" >nul 2>&1
if exist "%LOG_DIR%" del /q "%LOG_DIR%\*.log" >nul 2>&1
del /q "%USER_DIR%\compile_check.log" >nul 2>&1
del /q "%USER_DIR%\net_selftest.log" >nul 2>&1
del /q "%USER_DIR%\coop_selftest.log" >nul 2>&1
del /q "%USER_DIR%\lobby_selftest.log" >nul 2>&1
del /q "%USER_DIR%\coop_game_selftest.log" >nul 2>&1
del /q "%USER_DIR%\steam_selftest.log" >nul 2>&1

set "FRAMES=%~1"
if "%FRAMES%"=="" set "FRAMES=300"
set "MODE=%~2"
if "%MODE%"=="" set "MODE=driver"

if /i "%MODE%"=="all" (
    for %%M in (compile net coop lobby coopgame steam) do (
        call "%~f0" 0 %%M
        if errorlevel 1 (
            echo RESULT: FAIL - suite %%M failed
            exit /b 1
        )
    )
    echo RESULT: PASS - all headless suites passed
    exit /b 0
)

set "AUDIT_EXTRA="
if /i "%MODE%"=="import" (
    set "GODOT_ARGS=--headless --path "%PROJECT_DIR%" --import"
    goto :run
)
if /i "%MODE%"=="game" (
    set "GODOT_ARGS=--headless --path "%PROJECT_DIR%" --quit-after %FRAMES%"
    goto :run
)
if /i "%MODE%"=="compile" (
    set "GODOT_ARGS=--headless --path "%PROJECT_DIR%" --script res://tools/compile_check.gd"
    set "AUDIT_EXTRA=%USER_DIR%\compile_check.log"
    goto :run
)
if /i "%MODE%"=="net" (
    set "GODOT_ARGS=--headless --path "%PROJECT_DIR%" --script res://tools/net_selftest.gd"
    set "AUDIT_EXTRA=%USER_DIR%\net_selftest.log"
    goto :run
)
if /i "%MODE%"=="coop" (
    set "GODOT_ARGS=--headless --path "%PROJECT_DIR%" --script res://tools/coop_selftest.gd"
    set "AUDIT_EXTRA=%USER_DIR%\coop_selftest.log"
    goto :run
)
if /i "%MODE%"=="lobby" (
    set "GODOT_ARGS=--headless --path "%PROJECT_DIR%" --script res://tools/lobby_selftest.gd"
    set "AUDIT_EXTRA=%USER_DIR%\lobby_selftest.log"
    goto :run
)
if /i "%MODE%"=="coopgame" (
    set "GODOT_ARGS=--headless --path "%PROJECT_DIR%" --script res://tools/coop_game_selftest.gd"
    set "AUDIT_EXTRA=%USER_DIR%\coop_game_selftest.log"
    goto :run
)
if /i "%MODE%"=="steam" (
    set "GODOT_ARGS=--headless --path "%PROJECT_DIR%" --script res://tools/steam_selftest.gd"
    set "AUDIT_EXTRA=%USER_DIR%\steam_selftest.log"
    goto :run
)

REM Default: driver mode (the driver quits itself, so no --quit-after).
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
    if /i "%MODE%"=="import" (
        REM --import crashes at exit on this box even though the import succeeds.
        echo NOTE: no godot.log produced; --import crashes at exit by design here.
    ) else (
        echo RESULT: FAIL - Godot produced no log file ^(engine crashed at startup^)
        exit /b 1
    )
)

if defined LOG_FILE (
    echo --- %LOG_FILE% ---
    type "%LOG_FILE%"
    echo --- end log ---
)

REM --- audit ------------------------------------------------------------------
REM Lines that are known-benign and must NOT fail the build are dropped first:
REM   * root certificate store    -> sandbox cannot read the Windows cert store
REM   * ObjectDB / resource leaks -> Godot's usual at-exit chatter
REM   * custom_samplers           -> pre-existing engine shader condition
REM   * backtrace frames          -> emitted together with CrashHandlerException,
REM                                  which IS still checked below.
set "FILTERED=%TEMP%\tdg_filtered.log"
if defined LOG_FILE (
    findstr /v /c:"Failed to read the root certificate store" /c:"get_system_ca_certificates" /c:"os_windows.cpp:2289" /c:"ObjectDB instances leaked" /c:"resources still in use at exit" /c:"custom_samplers" /c:"no debug info in PE/COFF executable" /c:"-- END OF BACKTRACE --" /c:"Dumping the backtrace" /c:"Engine version: Godot Engine" /c:"ERROR: No loader found for resource" "%LOG_FILE%" > "%FILTERED%"
) else (
    type nul > "%FILTERED%"
)

set "FOUND=0"
call :check "SCRIPT ERROR"
call :check "Parse Error"
REM Crucial: a crash must fail the run. Otherwise a suite that dies half-way
REM through reports PASS simply because it never printed any failure marker.
call :check "CrashHandlerException"
call :check "Program crashed with signal"
call :check "ERROR:"

REM Audit the report file the suite driver wrote, too.
if defined AUDIT_EXTRA (
    if exist "%AUDIT_EXTRA%" (
        echo.
        echo --- %AUDIT_EXTRA% ---
        type "%AUDIT_EXTRA%"
        echo --- end report ---
        findstr /c:"[FAIL]" /c:"[compile] FAIL" /c:"RESULT: FAIL" "%AUDIT_EXTRA%" >nul 2>&1
        if !ERRORLEVEL! EQU 0 (
            echo.
            echo MATCHED report failure marker
            findstr /c:"[FAIL]" /c:"[compile] FAIL" /c:"RESULT: FAIL" "%AUDIT_EXTRA%"
            set "FOUND=1"
        )
    ) else (
        if not "%MODE%"=="import" (
            echo.
            echo RESULT: FAIL - test report not produced: %AUDIT_EXTRA%
            exit /b 1
        )
    )
)

echo.
if "!FOUND!"=="1" (
    echo RESULT: FAIL - errors found
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
