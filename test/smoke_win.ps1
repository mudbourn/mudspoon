# =============================================================================
# smoke_win.ps1 -- run the hs.* smoke suite under mudspoon on Windows.
#
#   pwsh -File test\smoke_win.ps1                 # core suite
#   pwsh -File test\smoke_win.ps1 -Net            # include network tests
#   pwsh -File test\smoke_win.ps1 -Webview        # bring up real WebView2 + test it
#   pwsh -File test\smoke_win.ps1 -Out C:\path\report.json
#
# =============================================================================
param(
    [switch]$Net,
    [switch]$Webview,
    [string]$Out
)

$ErrorActionPreference = "Continue"
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo    = Split-Path -Parent $here                      # ...\Main
$smoke   = Join-Path $here "smoke.lua"
$runner  = Join-Path $repo "main.lua"

if (-not $Out) { $Out = Join-Path $repo "smoke_report_mudspoon.json" }

# Locate the bundled Lua runtime.
$lua = Join-Path $repo "runtime\lua.exe"
if (-not (Test-Path $lua)) { Write-Error "runtime\lua.exe not found. Run setup.ps1."; exit 2 }

$env:MUDSPOON_SMOKE     = $smoke
$env:MUDSPOON_SMOKE_OUT = $Out
if ($Net)     { $env:MUDSPOON_SMOKE_NET = "1" } else { Remove-Item Env:MUDSPOON_SMOKE_NET -ErrorAction SilentlyContinue }
if ($Webview) { $env:MUDSPOON_WEBVIEW   = "1" } else { Remove-Item Env:MUDSPOON_WEBVIEW   -ErrorAction SilentlyContinue }

Push-Location $repo
try {
    & $lua -E $runner
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "smoke report: $Out"
Write-Host "exit code   : $code  (0=all pass, 1=failure, 2=harness error)"
exit $code
