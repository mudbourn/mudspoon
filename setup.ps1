# mudspoon Windows setup #
    # Installs LuaJIT on a bare rig, pins it to a stable folder, and fixes
    # PATH for both future shells and this one, then verifies it runs.
    # Run in PowerShell:
    #     powershell -ExecutionPolicy Bypass -File .\setup.ps1
# END #

$ErrorActionPreference = "Stop"

# Config #
    $InstallDir = "C:\tools\luajit"
    $WingetId   = "DEVCOM.LuaJIT"
# END #

# Ensure winget #
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget not found. Install 'App Installer' from the Microsoft Store, then re-run."
    }
# END #

# Install runtime dependency #
    winget install --id Microsoft.VCRedist.2015+.x64 --force `
        --accept-source-agreements --accept-package-agreements
# END #

# Install LuaJIT #
    winget install --id $WingetId --force `
        --accept-source-agreements --accept-package-agreements
# END #

# Locate the real binary #
    $roots = @(
        "$env:LOCALAPPDATA\Programs\LuaJIT",
        "$env:ProgramFiles",
        "${env:ProgramFiles(x86)}",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links"
    )

    $exe = $null
    foreach ($r in $roots) {
        if (Test-Path $r) {
            $hit = Get-ChildItem $r -Recurse -Filter luajit.exe -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if ($hit) { $exe = $hit.FullName; break }
        }
    }

    if (-not $exe) {
        throw "LuaJIT reported installed but no luajit.exe was placed. Use the from-source build in setup.sh."
    }
# END #

# Pin into a stable folder #
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $srcDir = Split-Path $exe

    Copy-Item "$srcDir\luajit.exe" $InstallDir -Force
    Get-ChildItem $srcDir -Filter *.dll -ErrorAction SilentlyContinue |
        Copy-Item -Destination $InstallDir -Force
# END #

# Fix PATH #
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -notlike "*$InstallDir*") {
        [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
        Write-Host "added $InstallDir to your user PATH"
    }

    $env:Path += ";$InstallDir"
# END #

# Verify #
    & "$InstallDir\luajit.exe" -v

    Write-Host ""
    Write-Host "luajit ready. Run the spike with:"
    Write-Host "    luajit .\spike_hook_loop_alert.lua"
# END #
