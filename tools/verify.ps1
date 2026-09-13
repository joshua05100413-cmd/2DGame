# Headless verification harness for the TowDownGame -> multiplayer project.
#
# Runs the game (or tools/headless_verify.gd) under headless Godot and FAILS on
# any engine/script error.
#
# THREE SANDBOX QUIRKS THIS WORKS AROUND
#   1. Godot needs a writable user:// directory. The default
#      (%APPDATA%\Godot\app_userdata\<project>) is NOT writable here, which makes
#      Godot die with "signal 11" right after:
#          ERROR: Could not create directory: 'user://logs'
#      -> APPDATA is redirected into the workspace.
#   2. Godot's stdout/stderr cannot be captured through a PowerShell pipeline or
#      a variable here (a variable yields ZERO lines -> false PASS).
#      Start-Process -RedirectStandardOutput is denied by the sandbox.
#      -> We audit Godot's OWN log file, user://logs/godot.log, which works.
#   3. Console output is interleaved/unordered; the log file is ordered.
#
# USAGE (execution policy may block .ps1; use -ExecutionPolicy Bypass)
#   powershell -ExecutionPolicy Bypass -File tools\verify.ps1
#   powershell -ExecutionPolicy Bypass -File tools\verify.ps1 -Frames 900
#   powershell -ExecutionPolicy Bypass -File tools\verify.ps1 -Mode game
#   powershell -ExecutionPolicy Bypass -File tools\verify.ps1 -Mode import
#   powershell -ExecutionPolicy Bypass -File tools\verify.ps1 -SelfTest   # must FAIL

param(
    [int]$Frames = 300,
    [ValidateSet('driver', 'game', 'import')]
    [string]$Mode = 'driver',
    [string]$Scene = '',
    [switch]$SelfTest,
    [string]$GodotExe = 'D:\Godot\Godot_v4.4-stable_win64.exe\Godot_v4.4-stable_win64.exe'
)

$ErrorActionPreference = 'Continue'

$projectDir = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path $GodotExe)) {
    Write-Host "Godot executable not found: $GodotExe" -ForegroundColor Red
    exit 2
}

# Quirk 1: writable user:// root inside the workspace.
$userData = Join-Path $projectDir '_userdata'
New-Item -ItemType Directory -Force -Path $userData | Out-Null
$env:APPDATA = $userData

$logDir = Join-Path $userData "Godot\app_userdata\Don't Stop\logs"
$logFile = Join-Path $logDir 'godot.log'

# Quirk 2: clear previous logs so we never audit a stale run.
if (Test-Path $logDir) { Remove-Item (Join-Path $logDir '*') -Force -ErrorAction SilentlyContinue }

$godotArgs = @('--headless', '--path', $projectDir)
switch ($Mode) {
    'import' {
        $godotArgs += '--import'
    }
    'driver' {
        # The driver quits itself, so no --quit-after (that would kill it early).
        $godotArgs += @('--script', 'res://tools/headless_verify.gd')
        $driverArgs = "--frames=$Frames"
        if ($SelfTest) { $driverArgs += ' --fail-test' }
        $godotArgs += @('--', $driverArgs)
    }
    'game' {
        $godotArgs += @('--quit-after', "$Frames")
        if ($Scene -ne '') { $godotArgs += $Scene }
    }
}

Write-Host "==> godot $($godotArgs -join ' ')" -ForegroundColor Cyan
Write-Host "    projectDir=$projectDir" -ForegroundColor DarkGray
Write-Host "    APPDATA=$env:APPDATA" -ForegroundColor DarkGray
Write-Host "    logDir=$logDir (exists=$(Test-Path $logDir))" -ForegroundColor DarkGray

# Console output is echoed for visibility (display only; not the audit).
# NOTE: piping to Out-Null truncates Godot's log file flush, so use Out-Host.
$console = & $GodotExe @godotArgs 2>&1
$console | ForEach-Object { "$_" } | Out-Host

# Prefer godot.log; if a crash left it truncated, fall back to the largest log.
# Godot flushes its log file asynchronously, so poll briefly instead of racing it.
$candidates = @()
for ($attempt = 0; $attempt -lt 30; $attempt++) {
    if (Test-Path $logDir) {
        $candidates = @(Get-ChildItem $logDir -Filter '*.log' -ErrorAction SilentlyContinue |
            Sort-Object Length -Descending)
        if ($candidates.Count -gt 0 -and $candidates[0].Length -gt 0) { break }
    }
    Start-Sleep -Milliseconds 100
}
if ($candidates.Count -eq 0) {
    Write-Host 'RESULT: FAIL - Godot produced no log file (engine likely crashed at startup)' -ForegroundColor Red
    Write-Host 'Console output was:' -ForegroundColor Red
    $console | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}

$logFile = $candidates[0].FullName
$lines = @(Get-Content $logFile | ForEach-Object { "$_" })

Write-Host ''
Write-Host "--- $(Split-Path $logFile -Leaf) ($($lines.Count) lines) ---" -ForegroundColor DarkGray
$lines | ForEach-Object { Write-Host $_ }
Write-Host '--- end log ---' -ForegroundColor DarkGray

# ---- audit -------------------------------------------------------------------
# Environmental / accepted noise. These must NOT fail the build:
#   * root certificate store     -> sandbox cannot read the Windows cert store
#   * ObjectDB / resource leaks  -> Godot's usual at-exit chatter
#   * shader sampler condition   -> pre-existing, non-fatal engine condition
#   * "at:" stack lines          -> belong to the preceding reported error
$noisePatterns = @(
    'Failed to read the root certificate store',
    'get_system_ca_certificates',
    'os_windows.cpp:2289',
    'ObjectDB instances leaked',
    'resources still in use at exit',
    'Condition "!actions.custom_samplers.has'
)

$errorPattern = 'SCRIPT ERROR|Parse Error|CrashHandlerException|ERROR:'
$errors = @()
$warnings = @()
$skippingContinuation = $false
foreach ($line in $lines) {
    # "   at: ..." lines are stack traces for the error reported just above.
    if ($line -match '^\s+at: ') { continue }

    $isNoise = $false
    foreach ($p in $noisePatterns) { if ($line -like "*$p*") { $isNoise = $true; break } }
    if ($isNoise) { continue }

    if ($line -match $errorPattern) { $errors += $line.Trim() }
    elseif ($line -match 'WARNING:') { $warnings += $line.Trim() }
}

$errors = @($errors | Select-Object -Unique)
$warnings = @($warnings | Select-Object -Unique)

if ($warnings.Count -gt 0) {
    Write-Host "WARNINGS ($($warnings.Count)):" -ForegroundColor Yellow
    $warnings | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
}

Write-Host ''
if ($errors.Count -gt 0) {
    Write-Host "RESULT: FAIL - $($errors.Count) error line(s):" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}

Write-Host 'RESULT: PASS - no script/engine errors' -ForegroundColor Green
exit 0
