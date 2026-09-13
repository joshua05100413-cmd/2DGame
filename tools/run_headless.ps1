# Headless Godot runner for CI-style verification of this project.
#
# WHY THIS EXISTS:
#   Godot needs a writable user:// directory (it writes shader caches, logs and
#   config there). Under the DSH file sandbox the default location
#   (%APPDATA%\Godot\app_userdata\<project>) is NOT writable, and Godot crashes
#   with "signal 11" immediately after:
#       ERROR: Could not create directory: 'user://logs'
#   Pointing APPDATA at a directory inside the workspace fixes it.
#
# USAGE:
#   pwsh -File tools/run_headless.ps1                 # boot main scene, 300 frames
#   pwsh -File tools/run_headless.ps1 -Frames 1200
#   pwsh -File tools/run_headless.ps1 -Scene res://game/hero/Hero.tscn
#   pwsh -File tools/run_headless.ps1 -Import         # (re)import assets only
#   pwsh -File tools/run_headless.ps1 -ExtraArgs @('--script','res://tools/foo.gd')

param(
    [int]$Frames = 300,
    [string]$Scene = "",
    [switch]$Import,
    [string]$GodotExe = "D:\Godot\Godot_v4.4-stable_win64.exe\Godot_v4.4-stable_win64.exe",
    [string[]]$ExtraArgs = @()
)

$ErrorActionPreference = "Continue"

$projectDir = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path $GodotExe)) {
    Write-Error "Godot executable not found: $GodotExe"
    exit 2
}

# Writable user:// root inside the workspace (see note above).
$userData = Join-Path $projectDir "_userdata"
New-Item -ItemType Directory -Force -Path $userData | Out-Null
$env:APPDATA = $userData

$argsList = @("--headless", "--path", $projectDir)
if ($Import) {
    $argsList += "--import"
} else {
    $argsList += "--quit-after"
    $argsList += "$Frames"
    if ($Scene -ne "") { $argsList += $Scene }
}
if ($ExtraArgs.Count -gt 0) { $argsList += $ExtraArgs }

Write-Host "==> godot $($argsList -join ' ')" -ForegroundColor Cyan
$output = & $GodotExe @argsList 2>&1

# "Failed to read the root certificate store" is an unavoidable sandbox artifact
# (no access to the Windows cert store); it is harmless and never a game bug.
$noise = @(
    'Failed to read the root certificate store',
    'get_system_ca_certificates',
    'os_windows.cpp:2289'
)
$lines = $output | ForEach-Object { "$_" } | Where-Object {
    $line = $_
    -not ($noise | Where-Object { $line -like "*$_*" })
}

$lines | ForEach-Object { Write-Host $_ }

$bad = $lines | Where-Object {
    $_ -match 'SCRIPT ERROR' -or
    ($_ -match '^ERROR' -and $_ -notmatch 'ObjectDB instances leaked') -or
    $_ -match 'CrashHandlerException' -or
    $_ -match 'Parse Error'
}

Write-Host ""
if ($bad) {
    Write-Host "RESULT: FAILED (see errors above)" -ForegroundColor Red
    exit 1
}
Write-Host "RESULT: OK (no script/engine errors)" -ForegroundColor Green
exit 0
