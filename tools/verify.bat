@echo off
REM ============================================================================
REM  TowDownGame headless verification entry point (Windows).
REM
REM  The same suites run on Linux/CI through tools/verify.sh. Keep the two files
REM  in sync when adding a mode.
REM
REM  WHY A .bat AND NOT A .ps1
REM    * PowerShell script execution is disabled on the dev machines, and nested
REM      `powershell -File` runs do not reliably inherit a redirected APPDATA,
REM      which previously produced false PASS results.
REM    * Godot's win64 binary is a GUI-subsystem executable: PowerShell's `&`
REM      call operator does NOT wait for it and its stdout is lost entirely.
REM      cmd waits, so the entry point lives in a .bat.
REM
REM  WHY THIS FILE IS PURE ASCII
REM    cmd reads .bat files using the OEM code page (936 on the dev machines),
REM    not UTF-8. Multi-byte comments get mangled into stray redirection
REM    characters and silently corrupt the batch structure -- which once
REM    produced a PASS while no test had actually run.
REM
REM  WHY --log-file
REM    Godot's own user://logs path depends on the platform (%APPDATA% on
REM    Windows, $XDG_DATA_HOME on Linux). Passing --log-file pins it to a path
REM    we choose, so this script never has to guess where Godot wrote its log.
REM    The self-test reports are written by the suites themselves into
REM    <project>/_userdata/reports/, which is likewise platform independent.
REM
REM  USAGE
REM    tools\verify.bat                         boot main scene, 300 frames
REM    tools\verify.bat 900                     ... 900 frames
REM    tools\verify.bat 300 game                run the real main scene
REM    tools\verify.bat 0   import              (re)import assets and audit
REM    tools\verify.bat 0   compile             compile every script/resource
REM    tools\verify.bat 0   net                 transport-layer loopback test
REM    tools\verify.bat 0   coop                co-op replication test
REM    tools\verify.bat 0   lobby               lobby UI test
REM    tools\verify.bat 0   coopgame            real level scene co-op test
REM    tools\verify.bat 0   steam               Steam backend fallback test
REM    tools\verify.bat 0   all                 every suite listed above
REM    tools\verify.bat 60  selftest            must FAIL (proves the audit works)
REM ============================================================================
setlocal EnableDelayedExpansion

set "PROJECT_DIR=%~dp0.."
pushd "%PROJECT_DIR%"
set "PROJECT_DIR=%CD%"
popd

set "GODOT_EXE=D:\Godot\Godot_v4.4-stable_win64.exe\Godot_v4.4-stable_win64.exe"
if not exist "%GODOT_EXE%" (
    echo RESULT: FAIL - Godot executable not found: %GODOT_EXE%
    echo Edit GODOT_EXE in this script, or install Godot 4.4 at that path.
    exit /b 2
)

REM Writable user:// root inside the workspace. The sandbox denies the real
REM %APPDATA%, and Godot then dies with signal 11 right after
REM "Could not create directory: 'user://logs'".
set "APPDATA=%PROJECT_DIR%\_userdata"
if not exist "%APPDATA%" mkdir "%APPDATA%" >nul 2>&1

set "WORK_DIR=%PROJECT_DIR%\_userdata"
set "RUN_LOG=%WORK_DIR%\logs\run.log"
set "REPORT_DIR=%WORK_DIR%\reports"
if not exist "%WORK_DIR%\logs" mkdir "%WORK_DIR%\logs" >nul 2>&1
if exist "%REPORT_DIR%" del /q "%REPORT_DIR%\*.log" >nul 2>&1
if exist "%RUN_LOG%" del /q "%RUN_LOG%" >nul 2>&1

REM A crash leaves a recovery lock behind; Godot then boots in recovery mode and
REM silently skips script execution, which looks like an empty run.
del /q "%WORK_DIR%\Godot\app_userdata\Don't Stop\.recovery_mode_lock" >nul 2>&1

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

REM --log-file must come BEFORE the "--" separator: anything after it is passed to
REM the script as a user argument instead of being consumed by the engine.
set "BASE_ARGS=--headless --path "%PROJECT_DIR%" --log-file "%RUN_LOG%""

REM A fresh checkout has no .godot/imported (it is gitignored). Without it every
REM texture and audio load fails with "Make sure resources have been imported by
REM opening the project in the editor at least once", and those failures cascade
REM into script parse errors -- so every suite fails for a reason that has
REM nothing to do with the code. Import once, quietly, before running anything.
REM (--import is known to crash at exit on some setups even when the import
REM itself succeeded, so its exit code is deliberately ignored here.)
if /i not "%MODE%"=="import" (
    if not exist "%PROJECT_DIR%\.godot\imported" (
        echo ==^> no import cache found; importing project assets first ^(may take a minute^)
        "%GODOT_EXE%" --headless --path "%PROJECT_DIR%" --import >nul 2>&1
    )
)

set "AUDIT_EXTRA="
if /i "%MODE%"=="import" (
    set "GODOT_ARGS=%BASE_ARGS% --import"
    goto :run
)
if /i "%MODE%"=="game" (
    set "GODOT_ARGS=%BASE_ARGS% --quit-after %FRAMES%"
    goto :run
)
if /i "%MODE%"=="compile" (
    set "GODOT_ARGS=%BASE_ARGS% --script res://tools/compile_check.gd"
    set "AUDIT_EXTRA=%REPORT_DIR%\compile_check.log"
    goto :run
)
if /i "%MODE%"=="net" (
    set "GODOT_ARGS=%BASE_ARGS% --script res://tools/net_selftest.gd"
    set "AUDIT_EXTRA=%REPORT_DIR%\net_selftest.log"
    goto :run
)
if /i "%MODE%"=="coop" (
    set "GODOT_ARGS=%BASE_ARGS% --script res://tools/coop_selftest.gd"
    set "AUDIT_EXTRA=%REPORT_DIR%\coop_selftest.log"
    goto :run
)
if /i "%MODE%"=="lobby" (
    set "GODOT_ARGS=%BASE_ARGS% --script res://tools/lobby_selftest.gd"
    set "AUDIT_EXTRA=%REPORT_DIR%\lobby_selftest.log"
    goto :run
)
if /i "%MODE%"=="coopgame" (
    set "GODOT_ARGS=%BASE_ARGS% --script res://tools/coop_game_selftest.gd"
    set "AUDIT_EXTRA=%REPORT_DIR%\coop_game_selftest.log"
    goto :run
)
if /i "%MODE%"=="steam" (
    set "GODOT_ARGS=%BASE_ARGS% --script res://tools/steam_selftest.gd"
    set "AUDIT_EXTRA=%REPORT_DIR%\steam_selftest.log"
    goto :run
)

REM Default: driver mode (the driver quits itself, so no --quit-after).
set "DRIVER_ARGS=--frames=%FRAMES%"
if /i "%MODE%"=="selftest" set "DRIVER_ARGS=%DRIVER_ARGS% --fail-test"
set "GODOT_ARGS=%BASE_ARGS% --script res://tools/headless_verify.gd -- %DRIVER_ARGS%"

:run
echo ==^> godot %GODOT_ARGS%
"%GODOT_EXE%" %GODOT_ARGS%
set "GODOT_RC=%ERRORLEVEL%"

echo.
if /i "%MODE%"=="import" goto :import_result
if not exist "%RUN_LOG%" (
    echo RESULT: FAIL - Godot produced no log at %RUN_LOG% ^(crashed before logging^)
    exit /b 1
)

echo --- %RUN_LOG% ---
type "%RUN_LOG%"
echo --- end log ---

REM --- audit ------------------------------------------------------------------
REM Lines that are known-benign and must NOT fail the build are dropped first:
REM   * root certificate store    -> the sandbox cannot read the Windows cert store
REM   * ObjectDB / resource leaks -> Godot's usual at-exit chatter
REM   * custom_samplers           -> pre-existing engine shader condition
REM   * backtrace frames          -> emitted together with CrashHandlerException,
REM                                  which IS still checked below
REM   * "No loader found"         -> res://shader/*.shader are Godot 3 leftovers,
REM                                  reported separately by compile_check
set "FILTERED=%WORK_DIR%\logs\filtered.log"
findstr /v /c:"Failed to read the root certificate store" /c:"get_system_ca_certificates" /c:"os_windows.cpp:2289" /c:"ObjectDB instances leaked" /c:"resources still in use at exit" /c:"custom_samplers" /c:"no debug info in PE/COFF executable" /c:"-- END OF BACKTRACE --" /c:"Dumping the backtrace" /c:"Engine version: Godot Engine" /c:"ERROR: No loader found for resource" "%RUN_LOG%" > "%FILTERED%"

set "FOUND=0"
call :check "SCRIPT ERROR"
call :check "Parse Error"
REM Crucial: a crash must fail the run. Otherwise a suite that dies half-way
REM through reports PASS simply because it never printed any failure marker.
call :check "CrashHandlerException"
call :check "Program crashed with signal"
call :check "ERROR:"

REM Audit the report the suite driver wrote, too.
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

REM --import crashes at exit on this box even though the import itself succeeds,
REM so its exit code is not meaningful. Every other mode must exit cleanly.
if /i not "%MODE%"=="import" (
    if not "%GODOT_RC%"=="0" (
        echo.
        echo MATCHED nonzero godot exit code: %GODOT_RC%
        set "FOUND=1"
    )
)

echo.
if "!FOUND!"=="1" (
    echo RESULT: FAIL - errors found
    exit /b 1
)

echo RESULT: PASS - no script/engine errors
exit /b 0

:import_result
REM Import is not a test. On a first run --import's log legitimately contains
REM resource errors, and Godot may still crash at exit afterwards; neither means
REM the import failed. The only meaningful check is whether the cache appeared.
if exist "%RUN_LOG%" (
    echo --- %RUN_LOG% ---
    type "%RUN_LOG%"
    echo --- end log ---
)
echo.
if exist "%PROJECT_DIR%\.godot\imported" (
    echo RESULT: PASS - assets imported into .godot\imported
    exit /b 0
)
echo RESULT: FAIL - import produced no .godot\imported
exit /b 1

:check
findstr /c:%1 "%FILTERED%" >nul 2>&1
if !ERRORLEVEL! EQU 0 (
    echo.
    echo MATCHED %~1
    findstr /c:%1 "%FILTERED%"
    set "FOUND=1"
)
exit /b 0
