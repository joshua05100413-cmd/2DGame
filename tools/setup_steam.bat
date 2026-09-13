@echo off
REM Install the GodotSteam GDExtension so the Steam P2P backend becomes usable.
REM
REM Usage:  tools\setup_steam.bat
REM
REM Why this is a script instead of committed binaries:
REM   The full plugin is ~92 MB of prebuilt libraries (Android alone is 33 MB)
REM   against a 45 MB repository. Committing only the Windows build is worse than
REM   either extreme: the .gdextension file lists per-platform libraries, and
REM   Godot logs "No GDExtension library found for current OS and architecture"
REM   whenever the running platform is absent -- which would fail the headless
REM   audit on the Linux CI runner. The runner currently never sees the extension
REM   at all, and that is what keeps CI deterministic. See .gitignore.
REM
REM Version pinning matters here. GodotSteam 4.22.1 is the "4.4+" GDExtension
REM line (compatibility_minimum = "4.4") built against Steamworks SDK 1.65.
REM GodotSteam versions track the Steamworks SDK, not the Godot version:
REM   Steamworks 1.65 -> GodotSteam 4.21+      (what we use)
REM   Steamworks 1.63-1.64 -> 4.17 - 4.20.1
REM   Steamworks 1.62 -> 4.14 - 4.16.2
REM An older copy built for Godot 4.2 used to live in this directory and made
REM Godot 4.4 crash on startup; it is gone now.
setlocal
set "VERSION=4.22.1"
set "TAG=v%VERSION%-gde"
set "ZIPNAME=godotsteam-%VERSION%-gdextension-plugin-4.4.zip"
set "URL=https://codeberg.org/godotsteam/godotsteam/releases/download/%TAG%/%ZIPNAME%"

set "PROJECT_DIR=%~dp0.."
pushd "%PROJECT_DIR%"
set "PROJECT_DIR=%CD%"
popd

set "WORK_DIR=%PROJECT_DIR%\_userdata"
set "CACHE_ZIP=%WORK_DIR%\godotsteam-%VERSION%-gde.zip"
set "STAGING=%WORK_DIR%\gs_staging"
set "TARGET=%PROJECT_DIR%\addons\godotsteam"

echo GodotSteam GDExtension %VERSION% (Godot 4.4+)
echo   target: %TARGET%
echo.

if not exist "%WORK_DIR%\logs" mkdir "%WORK_DIR%\logs" >nul 2>&1

REM Godot scans every *.gdextension under res://, so anything we unpack inside
REM the project is a second registration of the same classes until it is removed.
REM _userdata\.gdignore keeps the engine out of this whole directory, which also
REM covers the staging copy below. Without it a leftover staging tree produces
REM "Attempt to register extension class 'Steam', which appears to be already
REM registered" and the engine fails to shut down cleanly.
if not exist "%WORK_DIR%\.gdignore" type nul > "%WORK_DIR%\.gdignore"

if exist "%CACHE_ZIP%" (
  echo Reusing cached download: %CACHE_ZIP%
) else (
  where curl >nul 2>&1
  if errorlevel 1 (
    echo [ERROR] curl.exe not found. It ships with Windows 10 1803 and later.
    echo         Download manually and place it at:
    echo         %CACHE_ZIP%
    echo         URL: %URL%
    exit /b 1
  )
  echo Downloading %ZIPNAME% ...
  curl -L --fail --progress-bar -o "%CACHE_ZIP%" "%URL%"
  if errorlevel 1 (
    echo [ERROR] Download failed. URL: %URL%
    exit /b 1
  )
)

if exist "%STAGING%" rmdir /s /q "%STAGING%" >nul 2>&1
echo Extracting ...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Expand-Archive -LiteralPath '%CACHE_ZIP%' -DestinationPath '%STAGING%' -Force"
if errorlevel 1 (
  echo [ERROR] Extraction failed. The cached archive may be corrupt:
  echo         %CACHE_ZIP%
  exit /b 1
)

if not exist "%STAGING%\addons\godotsteam\godotsteam.gdextension" (
  echo [ERROR] Unexpected archive layout: addons\godotsteam was not found inside.
  exit /b 1
)

if exist "%TARGET%" rmdir /s /q "%TARGET%" >nul 2>&1
if not exist "%PROJECT_DIR%\addons" mkdir "%PROJECT_DIR%\addons" >nul 2>&1
robocopy "%STAGING%\addons\godotsteam" "%TARGET%" /E /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 (
  echo [ERROR] Copy failed.
  exit /b 1
)
rmdir /s /q "%STAGING%" >nul 2>&1

REM The old committed copy shipped a .gdignore that kept the extension switched
REM off. If one survives, the extension silently never loads and the lobby shows
REM Steam P2P as unavailable with no hint as to why.
if exist "%TARGET%\.gdignore" del /q "%TARGET%\.gdignore"

REM A crash leaves a recovery lock behind and Godot then boots in recovery mode,
REM skipping script execution entirely -- which looks like an empty, silent run.
if exist "%WORK_DIR%\Godot\app_userdata\Don't Stop\.recovery_mode_lock" ^
  del /q "%WORK_DIR%\Godot\app_userdata\Don't Stop\.recovery_mode_lock" >nul 2>&1

REM .godot/extension_list.cfg records which .gdextension files the engine loads.
REM It is rebuilt by a project scan, so drop it and let the next run regenerate it.
if exist "%PROJECT_DIR%\.godot\extension_list.cfg" del /q "%PROJECT_DIR%\.godot\extension_list.cfg"

echo.
echo Installed. Engine will rescan on the next run.
echo.
echo Verifying (this also rebuilds .godot/extension_list.cfg) ...
call "%PROJECT_DIR%\tools\verify.bat" 0 steam
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
  echo [WARN] The steam suite did not pass. Inspect _userdata\reports\steam_selftest.log
  echo        A missing Steam client is expected to show up as "Steam client not
  echo        running" -- that is reported honestly and is not an install failure.
)
echo Next: start and sign in to Steam, then pick Steam P2P in the in-game lobby.
endlocal
