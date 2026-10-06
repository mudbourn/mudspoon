# Installs the WebView2 runtime when missing, used by the installer #
$ErrorActionPreference = "Stop"

$guid = "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"

function Have-WebView2 {
    $keys = @(
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$guid",
        "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$guid",
        "HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$guid"
    )

    foreach ($k in $keys) {
        try {
            $pv = (Get-ItemProperty -Path $k -Name pv -ErrorAction Stop).pv
            if ($pv -and $pv -ne "0.0.0.0") { return $true }
        } catch {}
    }

    return $false
}

if (Have-WebView2) { exit 0 }

try {
    winget install --id Microsoft.EdgeWebView2Runtime --silent --accept-source-agreements --accept-package-agreements
} catch {}

if (Have-WebView2) { exit 0 }

try {
    $boot = Join-Path $env:TEMP "MicrosoftEdgeWebview2Setup.exe"
    Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/p/?LinkId=2124703" -OutFile $boot
    Start-Process -FilePath $boot -ArgumentList "/silent", "/install" -Wait
} catch {}

if (Have-WebView2) { exit 0 }

exit 1
