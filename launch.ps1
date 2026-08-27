# mudspoon launcher: the Windows equivalent of double-clicking Hammerspoon.app #
    # mudspoon is the host (a Hammerspoon port). mudscript is the elaborate macro
    # it loads from ../.hammerspoon. On macOS you double-click Hammerspoon.app and
    # everything just works; on Windows there was no host app at all -- you had to
    # hand-install LuaJIT, the WebView2 runtime, a POSIX shell, know to set
    # MUDSPOON_WEBVIEW=1, and run luajit from the right folder at a physical console.
    #
    # This script folds every one of those steps into one launch: it preflights and
    # (on first run) auto-installs the dependencies with winget, puts WebView2Loader.dll
    # on the DLL search path, enables the webview UI, then starts the host WINDOWLESS
    # and detached so it keeps running after this launcher exits -- like the .app does.
    #
    # Double-click Mudspoon.cmd (which calls this). Or run directly:
    #     powershell -ExecutionPolicy Bypass -File .\launch.ps1
    # Flags:
    #     -Foreground   run in this console (see boot log live; Ctrl+C stops it)
    #     -NoWebview    boot without the webview UI (headless macro host only)
    #     -SkipDeps     skip the dependency preflight (fastest re-launch)
# END #

param(
    [switch]$Foreground,
    [switch]$NoWebview,
    [switch]$SkipDeps
)

$ErrorActionPreference = "Stop"

# Config #
    $Root       = $PSScriptRoot
    $InstallDir = "C:\tools\luajit"
    # Evergreen WebView2 runtime's registered product GUID (stable, Microsoft-assigned).
    $WV2_GUID   = "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
# END #

# Small helpers #
    function Info($m) { Write-Host "[mudspoon] $m" }
    function Warn($m) { Write-Host "[mudspoon] $m" -ForegroundColor Yellow }
    function Have($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

    function Winget-Install($id) {
        if (-not (Have winget)) {
            throw "winget not found. Install 'App Installer' from the Microsoft Store, then re-launch."
        }
        Info "installing $id ..."
        winget install --id $id --silent --accept-source-agreements --accept-package-agreements
    }
# END #

# Resolve luajit.exe: PATH, then the pinned folder, else winget-install + pin #
    function Find-LuaJITExe {
        if (Have luajit) { return (Get-Command luajit).Source }
        if (Test-Path "$InstallDir\luajit.exe") { return "$InstallDir\luajit.exe" }
        return $null
    }

    # Absorbs setup.ps1's locate-and-pin so a fresh rig needs nothing pre-done.
    function Install-LuaJIT {
        Winget-Install "Microsoft.VCRedist.2015+.x64"   # LuaJIT links the VC++ runtime
        Winget-Install "DEVCOM.LuaJIT"

        $roots = @(
            "$env:LOCALAPPDATA\Programs\LuaJIT",
            "$env:ProgramFiles", "${env:ProgramFiles(x86)}",
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

        # Pin into a stable folder so future launches resolve it without a PATH hunt.
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

# WebView2 runtime present? (registry, both 64/32-bit and per-user hives) #
    # The shell AND the loading screen are both hs.webview (WebView2). Without the
    # Evergreen runtime the views come up but never paint -- so treat it as required.
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

# A POSIX sh for mac/'s shell-outs (mkdir -p, chmod, guardian hashing, ...) #
    # run_mudscript.lua probes these same paths for $MUDSPOON_SH. If none exists,
    # those file ops silently no-op -- so make sure git-for-Windows (which ships sh)
    # is present, and just warn if we cannot get one rather than blocking the boot.
    function Have-Sh {
        $cands = @(
            "$Root\bin\busybox.exe", "$Root\bin\sh.exe",
            "C:\Program Files\Git\bin\sh.exe", "C:\Program Files\Git\usr\bin\sh.exe",
            "C:\Program Files (x86)\Git\bin\sh.exe"
        )
        foreach ($c in $cands) { if (Test-Path $c) { return $true } }
        return $false
    }
# END #

# Preflight: install anything missing (idempotent; fast when already satisfied) #
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

    # Sanity: LuaJIT actually executes (catches a missing VC++ runtime on a stale pin).
    try {
        & $luajit -v | Out-Null
    } catch {
        Warn "luajit failed to start -- (re)installing the VC++ runtime it links ..."
        Winget-Install "Microsoft.VCRedist.2015+.x64"
        & $luajit -v | Out-Null   # let a still-broken runtime surface loudly here
    }
# END #

# Launch the host #
    # WebView2Loader.dll ships in the repo root; prepend Root to PATH and run FROM Root
    # so LoadLibrary("WebView2Loader.dll") resolves without copying the DLL around.
    $env:Path = "$Root;$env:Path"
    if (-not $NoWebview) { $env:MUDSPOON_WEBVIEW = "1" }

    $entry = Join-Path $Root "run_mudscript.lua"
    if (-not (Test-Path $entry)) { throw "run_mudscript.lua not found next to launch.ps1 ($entry)." }

    if ($Foreground) {
        # Attached: boot log streams to this console, Ctrl+C stops the host. Good for
        # first-light debugging (pair with $env:MUDSPOON_WEBVIEW_TRACE = "1").
        Info "starting mudspoon in the foreground (Ctrl+C to stop) ..."
        Push-Location $Root
        try { & $luajit $entry } finally { Pop-Location }
        exit $LASTEXITCODE
    } else {
        # Detached + hidden: the host keeps running after this launcher exits, with no
        # console window -- the closest Windows gets to the always-resident .app. The
        # low-level keyboard/mouse hooks pump on the host's own runloop, so no visible
        # window is needed. Diagnostics still tee to ..\.hammerspoon\mudspoon.log.
        Start-Process -FilePath $luajit -ArgumentList $entry `
                      -WorkingDirectory $Root -WindowStyle Hidden
        Info "mudspoon is running (windowless). Quit from its menubar, or run Stop-Mudspoon.cmd."
        $logDir = (Resolve-Path (Join-Path $Root "..")).Path
        Info "boot log: $logDir\.hammerspoon\mudspoon.log"
    }
# END #
