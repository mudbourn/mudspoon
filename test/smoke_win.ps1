# =============================================================================
# smoke_win.ps1 -- run the hs.* smoke suite under mudspoon on Windows.
#
#   pwsh -File test\smoke_win.ps1                 # core suite
#   pwsh -File test\smoke_win.ps1 -Net            # include network tests
#   pwsh -File test\smoke_win.ps1 -Webview        # bring up real WebView2 + test it
#   pwsh -File test\smoke_win.ps1 -Out C:\path\report.json
#
# Boots run_mudscript.lua with MUDSPOON_SMOKE set, so the suite runs against the
# exact `hs` mudscript sees, then exits (0 = all pass, 1 = a failure, 2 = harness
# error). The report JSON path is printed at the end -- feed it to diff_smoke.lua
# alongside the Mac report.
# =============================================================================
param(
    [switch]$Net,
    [switch]$Webview,
    [string]$Out
)

# "Continue", not "Stop": run_mudscript.lua writes a diagnostic os.exit line to
# stderr on a non-zero suite result, and under "Stop" PowerShell would surface
# that native stderr as a terminating error. The suite's exit code is the result.
$ErrorActionPreference = "Continue"
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo    = Split-Path -Parent $here                      # ...\Main
$smoke   = Join-Path $here "smoke.lua"
$runner  = Join-Path $repo "run_mudscript.lua"

if (-not $Out) { $Out = Join-Path $repo "smoke_report_mudspoon.json" }

# Locate luajit: PATH first, then the known install.
$luajit = (Get-Command luajit -ErrorAction SilentlyContinue).Source
if (-not $luajit) {
    $cand = "$env:LOCALAPPDATA\Programs\LuaJIT\bin\luajit.exe"
    if (Test-Path $cand) { $luajit = $cand }
}
if (-not $luajit) { Write-Error "luajit not found on PATH or in %LOCALAPPDATA%\Programs\LuaJIT\bin"; exit 2 }

$env:MUDSPOON_SMOKE     = $smoke
$env:MUDSPOON_SMOKE_OUT = $Out
if ($Net)     { $env:MUDSPOON_SMOKE_NET = "1" } else { Remove-Item Env:MUDSPOON_SMOKE_NET -ErrorAction SilentlyContinue }
if ($Webview) { $env:MUDSPOON_WEBVIEW   = "1" } else { Remove-Item Env:MUDSPOON_WEBVIEW   -ErrorAction SilentlyContinue }

Push-Location $repo
try {
    & $luajit $runner
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "smoke report: $Out"
Write-Host "exit code   : $code  (0=all pass, 1=failure, 2=harness error)"
exit $code
