# Stop the windowless mudspoon host (see Stop-Mudspoon.cmd) #
    # Targets only luajit.exe processes whose command line runs run_mudscript.lua.
    # With -Root only processes whose command line mentions that folder match, and
    # the matching watchdog is stopped too. -Tray also stops the tray app there.
param(
    [string]$Root,
    [switch]$Tray
)

function Matches-Root($proc, $pattern) {
    if (-not ($proc.CommandLine -match $pattern)) { return $false }
    if (-not $Root) { return $true }
    return $proc.CommandLine.ToLower().Contains($Root.ToLower())
}

$found = $false

Get-CimInstance Win32_Process -Filter "Name='luajit.exe'" |
    Where-Object { Matches-Root $_ "run_mudscript" } |
    ForEach-Object {
        Write-Host "[hammerspoon] stopping pid $($_.ProcessId)"
        Stop-Process -Id $_.ProcessId -Force
        $found = $true
    }

if ($Root) {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { Matches-Root $_ "watchdog\.ps1" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
}

if ($Root -and $Tray) {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { ($_.ProcessId -ne $PID) -and (Matches-Root $_ "tray\.ps1") } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
}

if (-not $found) { Write-Host "[hammerspoon] no running host found" }
# END #
