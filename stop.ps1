# Stop the windowless mudspoon host #
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

    $stopped = @()

    Get-CimInstance Win32_Process -Filter "Name='luajit.exe'" |
        Where-Object { Matches-Root $_ "run_mudscript" } |
        ForEach-Object {
            Write-Host "[hammerspoon] stopping pid $($_.ProcessId)"

            Stop-Process -Id $_.ProcessId -Force

            $stopped += $_.ProcessId

            $found = $true
        }

    if ($Root) {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { Matches-Root $_ "watchdog\.ps1" } |
            ForEach-Object {
                Stop-Process -Id $_.ProcessId -Force

                $stopped += $_.ProcessId
            }

        Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" |
            Where-Object { Matches-Root $_ "." } |
            ForEach-Object {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue

                $stopped += $_.ProcessId
            }
    }

    if ($Root -and $Tray) {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { ($_.ProcessId -ne $PID) -and (Matches-Root $_ "tray\.ps1") } |
            ForEach-Object {
                Stop-Process -Id $_.ProcessId -Force

                $stopped += $_.ProcessId
            }
    }

    # Waits for stopped processes to release their files
    if ($stopped) {
        Wait-Process -Id $stopped -Timeout 10 -ErrorAction SilentlyContinue
    }

    if (-not $found) { Write-Host "[hammerspoon] no running host found" }
# END #
