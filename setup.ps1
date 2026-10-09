# mudspoon Windows setup #
    # Checks the Lua 5.4 runtime in runtime\ (lua.exe, lua54.dll, cffi.dll) and
    # verifies that it loads the ffi module.
    # Run in PowerShell:
    #     powershell -ExecutionPolicy Bypass -File .\setup.ps1
    # Pass -Smoke to run the smoke suite right after. Physical console only, not RDP.
    #     powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Smoke
# END #

param([switch]$Smoke)

$ErrorActionPreference = "Stop"

# Config #
    $RuntimeDir = Join-Path $PSScriptRoot "runtime"
    $Required   = @("lua.exe", "lua54.dll", "cffi.dll")
# END #

# Check runtime files #
    foreach ($name in $Required) {
        if (-not (Test-Path (Join-Path $RuntimeDir $name))) {
            throw "runtime\$name is missing. Restore the runtime folder from the repo."
        }
    }
# END #

# Verify #
    $lua = Join-Path $RuntimeDir "lua.exe"

    & $lua -E -v

    & $lua -E -e "local ffi = require('cffi'); assert(ffi.C.GetTickCount() > 0)"

    if ($LASTEXITCODE -ne 0) { throw "runtime\lua.exe could not load cffi.dll." }

    Write-Host ""
    Write-Host "Lua runtime ready. Start the host with:"
    Write-Host "    .\Mudspoon.cmd"
    Write-Host "or run the smoke suite with:"
    Write-Host "    powershell -File .\test\smoke_win.ps1"
# END #

# Smoke test #
    if ($Smoke) {
        $suite = Join-Path $PSScriptRoot "test\smoke_win.ps1"

        & powershell -NoProfile -ExecutionPolicy Bypass -File $suite

        exit $LASTEXITCODE
    }
# END #
