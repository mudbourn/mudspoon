# mudspoon watchdog: frees system input if the host's runloop hangs #
    # The host owns global low-level keyboard/mouse hooks on one thread. If a macro
    # hangs that thread, system input can lock up hard. The host writes a heartbeat
    # file every runloop tick; this monitor kills the host when the heartbeat goes
    # stale while the process is still alive, turning a hard freeze into a few-second
    # blip. It exits on its own when the host exits normally.
    #
    # Started detached by launch.ps1. Not meant to be run by hand.
# END #

param(
    [Parameter(Mandatory = $true)][int]$HostPid,
    [Parameter(Mandatory = $true)][string]$Heartbeat,
    [int]$StaleSeconds = 6,
    [int]$GraceSeconds = 20,
    [string]$LogFile
)

$ErrorActionPreference = "SilentlyContinue"

# Startup grace: boot does heavy work before the runloop settles into a steady beat. #
    Start-Sleep -Seconds $GraceSeconds
# END #

# Monitor loop #
    while ($true) {
        $proc = Get-Process -Id $HostPid -ErrorAction SilentlyContinue
        if (-not $proc) { break }

        $age = $null
        if (Test-Path $Heartbeat) {
            $age = ((Get-Date) - (Get-Item $Heartbeat).LastWriteTime).TotalSeconds
        }

        if ($null -ne $age -and $age -gt $StaleSeconds) {
            Stop-Process -Id $HostPid -Force -ErrorAction SilentlyContinue
            if ($LogFile) {
                $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                "[$stamp] watchdog: host pid $HostPid runloop stalled ${age}s > ${StaleSeconds}s, killed to free input." | Out-File -FilePath $LogFile -Append -Encoding utf8
            }
            break
        }

        Start-Sleep -Seconds 2
    }
# END #
