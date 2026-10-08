# Builds installer\Output\Mudspoon-Setup.exe #
    # Stages the host, LuaJIT and a deployed copy of mudscript, generates the icon
    # and wizard images, then compiles Mudspoon.iss with Inno Setup 6.
    # Usage: powershell -ExecutionPolicy Bypass -File installer\build.ps1
param(
    [string]$Mudscript,
    [string]$LuaJitDir = "C:\tools\luajit"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

# Paths #
    $Here    = $PSScriptRoot
    $Repo    = Split-Path $Here -Parent
    $Share   = Split-Path $Repo -Parent
    $Build   = Join-Path $Here "build"
    $Stage   = Join-Path $Build "stage"
    $Assets  = Join-Path $Here "assets"
    $Png     = Join-Path $Repo "hammerspoon400x400.png"
    $Version = (Get-Content (Join-Path $Here "VERSION") -Raw).Trim()

    if (-not $Mudscript) { $Mudscript = Join-Path $Share "mudscript" }
# END #

# Find ISCC.exe, installing Inno Setup 6 with winget when absent #
    function Find-Iscc {
        $cands = @(
            "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
            "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
            "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
        )

        foreach ($c in $cands) { if (Test-Path $c) { return $c } }

        return $null
    }

    $iscc = Find-Iscc

    if (-not $iscc) {
        winget install --id JRSoftware.InnoSetup -e --silent --accept-source-agreements --accept-package-agreements
        $iscc = Find-Iscc
    }

    if (-not $iscc) { throw "ISCC.exe not found and the winget install did not provide it." }
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

    function Fill-Gradient($g, $w, $h) {
        $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
        $top = [System.Drawing.Color]::FromArgb(34, 40, 62)
        $bottom = [System.Drawing.Color]::FromArgb(10, 12, 20)
        $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $top, $bottom, 90)
        $g.FillRectangle($brush, $rect)
        $brush.Dispose()
    }

    function New-WizardImage($scale, $path) {
        $w = 164 * $scale
        $h = 314 * $scale
        $c = New-Canvas $w $h
        $g = $c.Graphics
        Fill-Gradient $g $w $h

        $src = [System.Drawing.Image]::FromFile($Png)
        $size = 120 * $scale
        $g.DrawImage($src, [int](($w - $size) / 2), [int](40 * $scale), $size, $size)
        $src.Dispose()

        $px = [System.Drawing.GraphicsUnit]::Pixel
        $font = New-Object System.Drawing.Font("Segoe UI Semibold", (13 * $scale), [System.Drawing.FontStyle]::Regular, $px)
        $sub = New-Object System.Drawing.Font("Segoe UI", (10 * $scale), [System.Drawing.FontStyle]::Regular, $px)
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = "Center"

        $box = New-Object System.Drawing.RectangleF(0, (180 * $scale), $w, (60 * $scale))
        $g.DrawString("Hammerspoon`nfor Windows", $font, [System.Drawing.Brushes]::White, $box, $fmt)

        $box2 = New-Object System.Drawing.RectangleF(0, (270 * $scale), $w, (24 * $scale))
        $g.DrawString("tester build", $sub, [System.Drawing.Brushes]::LightGray, $box2, $fmt)

        $c.Bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Bmp)
        $g.Dispose()
        $c.Bitmap.Dispose()
    }

    function New-SmallImage($scale, $path) {
        $w = 55 * $scale
        $c = New-Canvas $w $w
        $g = $c.Graphics
        Fill-Gradient $g $w $w

        $src = [System.Drawing.Image]::FromFile($Png)
        $size = 43 * $scale
        $g.DrawImage($src, [int](($w - $size) / 2), [int](($w - $size) / 2), $size, $size)
        $src.Dispose()

        $c.Bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Bmp)
        $g.Dispose()
        $c.Bitmap.Dispose()
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

# Generate icon and wizard images #
    New-Item -ItemType Directory -Force -Path $Assets | Out-Null

    New-Icon (Join-Path $Assets "mudspoon.ico")
    New-WizardImage 1 (Join-Path $Assets "wizard.bmp")
    New-WizardImage 2 (Join-Path $Assets "wizard@2x.bmp")
    New-SmallImage 1 (Join-Path $Assets "wizard_small.bmp")
    New-SmallImage 2 (Join-Path $Assets "wizard_small@2x.bmp")
# END #

# Stage the host #
    if (Test-Path $Build) { Remove-Item -Recurse -Force $Build }

    $app = Join-Path $Stage "app"
    New-Item -ItemType Directory -Force -Path $app | Out-Null

    $topFiles = @(
        "run_mudscript.lua",
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

    foreach ($d in @("hs", "bin")) {
        Copy-Item (Join-Path $Repo $d) (Join-Path $app $d) -Recurse
    }

    Get-ChildItem $app -Recurse -File |
        Where-Object { $_.Extension -in @(".md", ".txt", ".log") -and $_.Name -ne "README.md" } |
        Remove-Item -Force

    Copy-Item (Join-Path $Assets "mudspoon.ico") $app
    Copy-Item (Join-Path $Here "VERSION") $app
# END #

# Stage LuaJIT and its VC++ runtime DLL #
    $lj = Join-Path $app "luajit"
    New-Item -ItemType Directory -Force -Path $lj | Out-Null

    Copy-Item (Join-Path $LuaJitDir "luajit.exe") $lj
    Copy-Item (Join-Path $LuaJitDir "lua51.dll") $lj
    Copy-Item (Join-Path $env:SystemRoot "System32\vcruntime140.dll") $lj
# END #

# Stage mudscript with the Windows deploy script #
    $hs = Join-Path $Stage ".hammerspoon"
    New-Item -ItemType Directory -Force -Path $hs | Out-Null

    $deploy = Join-Path $Repo "deploy_mudscript.ps1"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $deploy -Repo $Mudscript -HS $hs -NoBackup | Out-Host

    if ($LASTEXITCODE -ne 0) { throw "deploy_mudscript.ps1 failed ($LASTEXITCODE)." }

    $templates = Join-Path $Mudscript "mac\templates"
    Copy-Item $templates (Join-Path $hs "templates") -Recurse -Force
# END #

# Compile #
    & $iscc "/DAppVersion=$Version" "/DStageDir=$Stage" "/DAssetsDir=$Assets" (Join-Path $Here "Mudspoon.iss")

    if ($LASTEXITCODE -ne 0) { throw "ISCC failed ($LASTEXITCODE)." }

    $setup = Join-Path $Here "Output\Mudspoon-Setup.exe"
    Write-Host ("Built {0} ({1:N1} MB)" -f $setup, ((Get-Item $setup).Length / 1MB))
# END #
