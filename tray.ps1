# Hammerspoon tray app: starts the host and owns the one notification-area icon #
    # Single instance. Started hidden by Mudspoon.vbs. -BugReport and -Autostart act once and exit.
param(
    [switch]$BugReport,
    [ValidateSet("on", "off")]
    [string]$Autostart
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"

# Config #
    $Root     = $PSScriptRoot
    $HomeDir  = Split-Path $Root -Parent
    $Config   = Join-Path $HomeDir ".hammerspoon"
    $BootLog  = Join-Path $Config "hammerspoon.log"
    $DataDir  = Join-Path $Config "data"
    $Launch   = Join-Path $Root "launch.ps1"
    $Stop     = Join-Path $Root "stop.ps1"
    $Vbs      = Join-Path $Root "Mudspoon.vbs"
    $RunKey   = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $RunName  = "Mudspoon"
    $Title    = "Hammerspoon"
# END #

# Single instance #
    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($true, "Local\MudspoonTray", [ref]$createdNew)

    $oneShot = $BugReport -or $Autostart

    if (-not $createdNew -and -not $oneShot) { exit 0 }
# END #

# Host control #
    function Get-HostProcess {
        Get-CimInstance Win32_Process -Filter "Name='luajit.exe'" |
            Where-Object {
                $_.CommandLine -match "run_mudscript" -and
                $_.CommandLine.ToLower().Contains($Root.ToLower())
            }
    }

    function Start-Host {
        Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Launch, "-SkipDeps"
        )
    }

    function Stop-Host {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Stop -Root $Root | Out-Null
    }

    function Restart-Host {
        Stop-Host
        Start-Sleep -Milliseconds 800
        Start-Host
    }
# END #

# Start at login #
    function Get-Autostart {
        $v = Get-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue
        return [bool]$v
    }

    function Set-Autostart($on) {
        if ($on) {
            $cmd = "wscript.exe `"$Vbs`""
            Set-ItemProperty -Path $RunKey -Name $RunName -Value $cmd
        } else {
            Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue
        }
    }
# END #

# Bug report #
    function Copy-Shared($src, $dst) {
        if (-not (Test-Path $src)) { return }

        $in = [IO.File]::Open($src, "Open", "Read", "ReadWrite")
        try {
            $out = [IO.File]::Create($dst)
            try { $in.CopyTo($out) } finally { $out.Dispose() }
        } finally { $in.Dispose() }
    }

    function Send-BugReport {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $work = Join-Path $env:TEMP "mudspoon-report-$stamp"
        New-Item -ItemType Directory -Force -Path $work | Out-Null

        $files = @(
            $BootLog,
            (Join-Path $DataDir "stderr.log"),
            (Join-Path $DataDir "watchdog.log"),
            (Join-Path $DataDir "probe.txt")
        )

        foreach ($f in $files) {
            Copy-Shared $f (Join-Path $work (Split-Path $f -Leaf))
        }

        $luajit = Join-Path $Root "luajit\luajit.exe"
        $ver = Join-Path $Root "VERSION"
        $info = @(
            "Hammerspoon for Windows: " + $(if (Test-Path $ver) { (Get-Content $ver -Raw).Trim() } else { "unknown" }),
            "Windows: " + [Environment]::OSVersion.VersionString,
            "Host running: " + [bool](Get-HostProcess),
            "LuaJIT: " + $(try { (& $luajit -v) -join " " } catch { "unavailable" })
        )
        Set-Content -Path (Join-Path $work "info.txt") -Value $info -Encoding ascii

        $desktop = [Environment]::GetFolderPath("Desktop")
        $zip = Join-Path $desktop "Mudspoon-bugreport-$stamp.zip"
        Compress-Archive -Path (Join-Path $work "*") -DestinationPath $zip -Force
        Remove-Item -Recurse -Force $work

        Start-Process -FilePath "explorer.exe" -ArgumentList "/select,`"$zip`""
    }

    if ($oneShot) {
        if ($BugReport) { Send-BugReport }

        if ($Autostart) { Set-Autostart ($Autostart -eq "on") }

        if ($createdNew) { $mutex.ReleaseMutex() }

        exit 0
    }
# END #

# Menu #
    $icon = New-Object System.Windows.Forms.NotifyIcon
    $icon.Icon = New-Object System.Drawing.Icon (Join-Path $Root "mudspoon.ico")
    $icon.Text = $Title
    $icon.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    $status = $menu.Items.Add("Status: starting")
    $status.Enabled = $false

    [void]$menu.Items.Add("-")

    $restart = $menu.Items.Add("Start Hammerspoon")
    $stopHost = $menu.Items.Add("Stop Hammerspoon")

    [void]$menu.Items.Add("-")

    $openLog = $menu.Items.Add("Open boot log")
    $openCfg = $menu.Items.Add("Open config folder")
    $report = $menu.Items.Add("Send bug report")

    [void]$menu.Items.Add("-")

    $login = New-Object System.Windows.Forms.ToolStripMenuItem("Start at login")
    $login.CheckOnClick = $true
    $login.Checked = Get-Autostart
    [void]$menu.Items.Add($login)

    [void]$menu.Items.Add("-")

    $quit = $menu.Items.Add("Quit")

    $icon.ContextMenuStrip = $menu
# END #

# Actions #
    function Show-Balloon($text) {
        $icon.BalloonTipTitle = $Title
        $icon.BalloonTipText = $text
        $icon.ShowBalloonTip(4000)
    }

    $restart.add_Click({ Restart-Host })

    $stopHost.add_Click({ Stop-Host })

    $openLog.add_Click({
        if (Test-Path $BootLog) {
            Start-Process -FilePath "notepad.exe" -ArgumentList "`"$BootLog`""
        } else {
            Show-Balloon "No boot log yet"
        }
    })

    $openCfg.add_Click({
        New-Item -ItemType Directory -Force -Path $Config | Out-Null
        Start-Process -FilePath "explorer.exe" -ArgumentList "`"$Config`""
    })

    $report.add_Click({
        try {
            Send-BugReport
        } catch {
            Show-Balloon "Bug report failed: $($_.Exception.Message)"
        }
    })

    $login.add_Click({ Set-Autostart $login.Checked })

    $quit.add_Click({
        $timer.Stop()
        $icon.Visible = $false
        $icon.Dispose()
        Stop-Host
        [System.Windows.Forms.Application]::Exit()
    })
# END #

# Status poll #
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 3000
    $timer.add_Tick({
        $up = [bool](Get-HostProcess)
        $status.Text = $(if ($up) { "Status: running" } else { "Status: stopped" })

        $restart.Text = $(if ($up) { "Restart Hammerspoon" } else { "Start Hammerspoon" })

        $stopHost.Enabled = $up
    })
    $timer.Start()
# END #

# Run #
    if (-not (Get-HostProcess)) { Start-Host }

    [System.Windows.Forms.Application]::Run()

    $mutex.ReleaseMutex()
# END #
