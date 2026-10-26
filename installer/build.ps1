# Builds installer\Output\Mudspoon.zip #
    # Usage: powershell -ExecutionPolicy Bypass -File installer\build.ps1
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

# Paths #
    $Here    = $PSScriptRoot
    $Repo    = Split-Path $Here -Parent
    $Build   = Join-Path $Here "build"
    $Stage   = Join-Path $Build "stage"
    $Assets  = Join-Path $Here "assets"
    $Png     = Join-Path $Repo "hammerspoon400x400.png"
# END #

# Image helpers #
    function New-Canvas($w, $h) {
        $bmp = New-Object System.Drawing.Bitmap($w, $h)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = "AntiAlias"
        $g.InterpolationMode = "HighQualityBicubic"
        $g.TextRenderingHint = "AntiAliasGridFit"

        return @{
            Bitmap = $bmp
            Graphics = $g
        }
    }

    function New-Icon($path) {
        $sizes = @(16, 32, 48, 256)
        $src = [System.Drawing.Image]::FromFile($Png)
        $images = @()

        foreach ($s in $sizes) {
            $c = New-Canvas $s $s
            $c.Graphics.DrawImage($src, 0, 0, $s, $s)
            $ms = New-Object System.IO.MemoryStream
            $c.Bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $images += , $ms.ToArray()
            $c.Graphics.Dispose()
            $c.Bitmap.Dispose()
        }

        $src.Dispose()

        $out = New-Object System.IO.MemoryStream
        $bw = New-Object System.IO.BinaryWriter($out)
        $bw.Write([uint16]0)
        $bw.Write([uint16]1)
        $bw.Write([uint16]$sizes.Count)

        $offset = 6 + 16 * $sizes.Count

        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
            $bw.Write([byte]$dim)
            $bw.Write([byte]$dim)
            $bw.Write([byte]0)
            $bw.Write([byte]0)
            $bw.Write([uint16]1)
            $bw.Write([uint16]32)
            $bw.Write([uint32]$images[$i].Length)
            $bw.Write([uint32]$offset)
            $offset += $images[$i].Length
        }

        foreach ($img in $images) { $bw.Write([byte[]]$img) }

        $bw.Flush()
        [System.IO.File]::WriteAllBytes($path, $out.ToArray())
    }
# END #

# Generate the icon #
    New-Item -ItemType Directory -Force -Path $Assets | Out-Null

    New-Icon (Join-Path $Assets "mudspoon.ico")
# END #

# Stage the host #
    if (Test-Path $Build) { Remove-Item -Recurse -Force $Build }

    $app = Join-Path $Stage "app"
    New-Item -ItemType Directory -Force -Path $app | Out-Null

    $topFiles = @(
        "main.lua",
        "launch.ps1",
        "stop.ps1",
        "watchdog.ps1",
        "tray.ps1",
        "Mudspoon.vbs",
        "Mudspoon.cmd",
        "Stop-Mudspoon.cmd",
        "hs.cmd",
        "WebView2Loader.dll",
        "README.md"
    )

    foreach ($f in $topFiles) { Copy-Item (Join-Path $Repo $f) $app }

    foreach ($d in @("hs", "bin", "compat")) {
        Copy-Item (Join-Path $Repo $d) (Join-Path $app $d) -Recurse
    }

    Get-ChildItem $app -Recurse -File |
        Where-Object { $_.Extension -in @(".md", ".txt", ".log") -and $_.Name -ne "README.md" } |
        Remove-Item -Force

    Copy-Item (Join-Path $Assets "mudspoon.ico") $app
    Copy-Item (Join-Path $Here "VERSION") $app
    Copy-Item (Join-Path $Here "wv2.ps1") $app
# END #

# Stage the Lua runtime #
    $rt = Join-Path $app "runtime"
    New-Item -ItemType Directory -Force -Path $rt | Out-Null

    foreach ($f in @("lua.exe", "lua54.dll", "cffi.dll")) {
        Copy-Item (Join-Path $Repo "runtime\$f") $rt
    }
# END #

# Package #
    $out = Join-Path $Here "Output"
    New-Item -ItemType Directory -Force -Path $out | Out-Null

    $zip = Join-Path $out "Mudspoon.zip"
    if (Test-Path $zip) { Remove-Item -Force $zip }

    Compress-Archive -Path $app -DestinationPath $zip

    Write-Host ("Built {0} ({1:N1} MB)" -f $zip, ((Get-Item $zip).Length / 1MB))
# END #
