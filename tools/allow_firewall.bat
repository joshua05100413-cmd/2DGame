@echo off
REM Allow incoming co-op connections on the given UDP port.
REM
REM Why this is needed:
REM Godot only gets a firewall rule the first time it listens, and Windows writes
REM that rule for whichever network profile was active at that moment. A machine
REM that was on a "Public" network back then ends up with a Public-only rule, and
REM the very same host is then silently unreachable after moving to a "Private"
REM one. The symptom is a client that sits on "connecting" and times out, with
REM nothing useful in either side's log.
REM
REM This adds a port-based rule that covers every profile, so it keeps working
REM when Windows reclassifies the network -- which it does on its own, without
REM asking.
REM
REM Usage:  right click -> Run as administrator
REM         allow_firewall.bat [port]      (default port: 27015)
setlocal
set PORT=%~1
if "%PORT%"=="" set PORT=27015
set RULE=Godot Coop UDP %PORT%

net session >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Administrator rights are required.
  echo         Right click this file and choose "Run as administrator".
  exit /b 1
)

echo Opening UDP %PORT% inbound for all network profiles...

REM Delete first so re-running updates the rule instead of stacking duplicates.
netsh advfirewall firewall delete rule name="%RULE%" >nul 2>&1
netsh advfirewall firewall add rule name="%RULE%" dir=in action=allow protocol=UDP localport=%PORT% profile=any
if errorlevel 1 (
  echo [ERROR] Could not add the rule.
  exit /b 1
)

echo.
netsh advfirewall firewall show rule name="%RULE%"
echo.
echo Done. The host can now be reached on UDP %PORT%.
endlocal
