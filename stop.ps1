# Stop the windowless mudspoon host #
    param(
        [string]$Root,
        [switch]$Tray
    )

    if (-not $Root) { $Root = $PSScriptRoot }

    function Matches-Root($proc, $pattern) {
        if (-not ($proc.CommandLine -match $pattern)) { return $false }

        if (-not $Root) { return $true }

        return $proc.CommandLine.ToLower().Contains($Root.ToLower())
    }

    $found = $false

    $stopped = @()

    Get-CimInstance Win32_Process -Filter "Name='lua.exe'" |
        Where-Object { Matches-Root $_ "main\.lua" } |
        ForEach-Object {
            Write-Host "[hammerspoon] stopping pid $($_.ProcessId)"

            Stop-Process -Id $_.ProcessId -Force

            $stopped += $_.ProcessId

            $found = $true
        }

    $config = if ($env:MUDSPOON_CONFIG_DIR) { $env:MUDSPOON_CONFIG_DIR } else { Join-Path $env:USERPROFILE ".hammerspoon" }

    $configKey = ([IO.Path]::GetFullPath($config)).TrimEnd('\').ToLower() + '\'

    # Hosts from any install that run on this config, found through their watchdog #
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.CommandLine -match 'watchdog\.ps1.*-HostPid\s+(\d+).*-Heartbeat\s+"?([^"]+?)"?(\s+-|$)' } |
            ForEach-Object {
                $hostPid = [int]$Matches[1]

                $beat = ([IO.Path]::GetFullPath($Matches[2])).ToLower()

                if ($beat.StartsWith($configKey) -and ($stopped -notcontains $hostPid)) {
                    if (Get-Process -Id $hostPid -ErrorAction SilentlyContinue) {
                        Write-Host "[hammerspoon] stopping pid $hostPid (shares $config)"

                        Stop-Process -Id $hostPid -Force -ErrorAction SilentlyContinue

                        $stopped += $hostPid

                        $found = $true
                    }

                    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue

                    $stopped += $_.ProcessId
                }
            }
    # END #

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
