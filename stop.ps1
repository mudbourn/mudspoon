# Stop the windowless mudspoon host (see Stop-Mudspoon.cmd) #
    # Targets only luajit.exe processes whose command line runs run_mudscript.lua,
    # so an unrelated luajit is never touched.
$found = $false
Get-CimInstance Win32_Process -Filter "Name='luajit.exe'" |
    Where-Object { $_.CommandLine -match "run_mudscript" } |
    ForEach-Object {
        Write-Host "[hammerspoon] stopping pid $($_.ProcessId)"
        Stop-Process -Id $_.ProcessId -Force
        $found = $true
    }
if (-not $found) { Write-Host "[hammerspoon] no running host found" }
