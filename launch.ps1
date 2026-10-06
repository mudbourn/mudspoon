# Launcher flags #
    param(
        [switch]$Foreground,
        [switch]$NoWebview,
        [switch]$SkipDeps,
        [switch]$NoGlass,
        [switch]$Dev
    )
# END #

$ErrorActionPreference = "Stop"

# Config #
    $Root       = $PSScriptRoot
    $InstallDir = "C:\tools\luajit"
    $Bundled    = Join-Path $Root "luajit\luajit.exe"

    # WebView2 runtime product GUID
    $WV2_GUID   = "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
# END #

# Small helpers #
    function Info($m) { Write-Host "[hammerspoon] $m" }

    function Warn($m) { Write-Host "[hammerspoon] $m" -ForegroundColor Yellow }

    function Have($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

    function Winget-Install($id) {
        if (-not (Have winget)) {
            throw "winget not found. Install 'App Installer' from the Microsoft Store, then re-launch."
        }

        Info "installing $id ..."

        winget install --id $id --silent --accept-source-agreements --accept-package-agreements
    }
# END #

# Resolve luajit.exe #
    function Find-LuaJITExe {
        if (Test-Path $Bundled) { return $Bundled }

        if (Have luajit) { return (Get-Command luajit).Source }

        if (Test-Path "$InstallDir\luajit.exe") { return "$InstallDir\luajit.exe" }

        return $null
    }

    # Installs LuaJIT with winget and pins it into the install folder
    function Install-LuaJIT {
        Winget-Install "Microsoft.VCRedist.2015+.x64"

        Winget-Install "DEVCOM.LuaJIT"

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
            throw "LuaJIT installed but no luajit.exe was placed. Build from source with setup.sh."
        }

        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

        $srcDir = Split-Path $exe

        Copy-Item "$srcDir\luajit.exe" $InstallDir -Force

        Get-ChildItem $srcDir -Filter *.dll -ErrorAction SilentlyContinue |
            Copy-Item -Destination $InstallDir -Force

        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")

        if ($userPath -notlike "*$InstallDir*") {
            [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
        }

        return "$InstallDir\luajit.exe"
    }
# END #

# WebView2 runtime check #
    function Have-WebView2 {
        $keys = @(
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$WV2_GUID",
            "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$WV2_GUID",
            "HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$WV2_GUID"
        )

        foreach ($k in $keys) {
            try {
                $pv = (Get-ItemProperty -Path $k -Name pv -ErrorAction Stop).pv

                if ($pv -and $pv -ne "0.0.0.0") { return $true }
            } catch {}
        }

        return $false
    }
# END #

# POSIX shell check #
    function Have-Sh {
        $cands = @(
            "$Root\bin\busybox.exe",
            "$Root\bin\sh.exe",
            "C:\Program Files\Git\bin\sh.exe",
            "C:\Program Files\Git\usr\bin\sh.exe",
            "C:\Program Files (x86)\Git\bin\sh.exe"
        )

        foreach ($c in $cands) { if (Test-Path $c) { return $true } }

        return $false
    }
# END #

# Dependency preflight #
    $luajit = Find-LuaJITExe

    if (-not $SkipDeps) {
        if (-not $luajit) {
            Info "LuaJIT not found -- installing (first-run setup) ..."

            $luajit = Install-LuaJIT
        }

        if (-not $NoWebview -and -not (Have-WebView2)) {
            Info "WebView2 runtime missing (needed for the shell + loading UI) -- installing ..."

            Winget-Install "Microsoft.EdgeWebView2Runtime"
        }

        if (-not (Have-Sh)) {
            Info "no POSIX shell found (mac/ shells out for file ops) -- installing Git for Windows ..."

            try { Winget-Install "Git.Git" } catch { Warn "could not install Git: $_" }

            if (-not (Have-Sh)) {
                Warn "still no sh on the standard paths -- some mac/ file ops will no-op."

                Warn "install Git for Windows, or drop sh.exe/busybox.exe into $Root\bin\."
            }
        }
    }

    if (-not $luajit) {
        throw "luajit.exe not found and -SkipDeps was set. Re-run without -SkipDeps, or run setup.ps1."
    }

    # Reinstalls the VC++ runtime when luajit fails to start
    try {
        & $luajit -v | Out-Null
    } catch {
        Warn "luajit failed to start -- (re)installing the VC++ runtime it links ..."

        Winget-Install "Microsoft.VCRedist.2015+.x64"

        & $luajit -v | Out-Null
    }
# END #

# Legacy Guardian task check #
    $guardian = Get-ScheduledTask -TaskName "mudscript Guardian" -ErrorAction SilentlyContinue

    $bareBat = $guardian.Actions |
        Where-Object { $_.Execute -match '\.(bat|cmd)"?$' } |
        Select-Object -First 1

    if ($bareBat) {
        $batPath = $bareBat.Execute.Trim('"')

        Warn "the 'mudscript Guardian' task opens a console window every 5 minutes, which steals focus."

        Warn "to run it hidden, paste this into an administrator PowerShell:"

        Warn "  Set-ScheduledTask -TaskName 'mudscript Guardian' -Action (New-ScheduledTaskAction -Execute 'C:\Windows\System32\conhost.exe' -Argument '--headless cmd /c `"$batPath`"')"
    }
# END #

# Launch the host #
    $env:Path = "$Root;$env:Path"

    if (-not $NoWebview) { $env:MUDSPOON_WEBVIEW = "1" }

    if ($Dev) { $env:MUDSPOON_IPC = "1" }

    if (-not $NoWebview -and -not $NoGlass) { $env:MUDSPOON_GLASS = "1" }

    $entry = Join-Path $Root "run_mudscript.lua"

    if (-not (Test-Path $entry)) { throw "run_mudscript.lua not found next to launch.ps1 ($entry)." }

    if ($Foreground) {
        Info "starting hammerspoon in the foreground (Ctrl+C to stop) ..."

        Push-Location $Root

        try { & $luajit $entry } finally { Pop-Location }

        exit $LASTEXITCODE
    } else {
        $hsData = Join-Path (Resolve-Path (Join-Path $Root "..")).Path ".hammerspoon\data"

        $hbFile = Join-Path $hsData ".ms_heartbeat"

        $env:MUDSPOON_HEARTBEAT_FILE = $hbFile

        # Seeds a fresh heartbeat for the watchdog
        try { Set-Content -Path $hbFile -Value "start" -Encoding utf8 } catch {}

        $hostProc = Start-Process -FilePath $luajit -ArgumentList $entry `
                      -WorkingDirectory $Root -WindowStyle Hidden -PassThru

        # Starts the watchdog beside the host
        $wd    = Join-Path $Root "watchdog.ps1"
        $wdLog = Join-Path $hsData "watchdog.log"

        Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            $wd,
            "-HostPid",
            $hostProc.Id,
            "-Heartbeat",
            $hbFile,
            "-LogFile",
            $wdLog
        )

        Info "hammerspoon is running (windowless). Quit from its menubar, or run Stop-Mudspoon.cmd."

        Info "watchdog armed -- frees input automatically if the host runloop ever stalls."

        $logDir = (Resolve-Path (Join-Path $Root "..")).Path

        Info "boot log: $logDir\.hammerspoon\hammerspoon.log"
    }
# END #
