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

    # Hosts whose command line is unreadable, such as elevated ones #
        $hidden = @(Get-CimInstance Win32_Process -Filter "Name='lua.exe'" |
            Where-Object { -not $_.CommandLine } |
            ForEach-Object { $_.ProcessId })

        $webviewHosts = @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" |
            Where-Object { $_.CommandLine -match 'webview-exe-name=lua\.exe' -and $_.CommandLine -match '\\Hammerspoon\\WebView2' } |
            ForEach-Object { $_.ParentProcessId })

        $denied = @()

        foreach ($id in (@($hidden) + @($webviewHosts) | Sort-Object -Unique)) {
            if ($stopped -contains $id) { continue }

            $proc = Get-Process -Id $id -ErrorAction SilentlyContinue

            if (-not $proc -or $proc.ProcessName -ne 'lua') { continue }

            Write-Host "[hammerspoon] stopping pid $id"

            try {
                Stop-Process -Id $id -Force -ErrorAction Stop

                $stopped += $id

                $found = $true
            }
            catch {
                $denied += $id
            }
        }

        if ($denied) {
            Write-Host "[hammerspoon] pid $($denied -join ',') runs as administrator, asking to elevate"

            $kill = 'Stop-Process -Force -Id ' + ($denied -join ',')

            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($kill))

            try {
                Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList '-NoProfile', '-EncodedCommand', $encoded

                $stopped += $denied

                $found = $true
            }
            catch {
                Write-Host "[hammerspoon] could not stop pid $($denied -join ',')"
            }
        }
    # END #

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
