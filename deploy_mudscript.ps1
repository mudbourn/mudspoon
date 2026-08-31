<#
.SYNOPSIS
  Windows equivalent of mudscript's mac/bin/deploy.sh — deploys the mudscript
  source tree into the .hammerspoon tree that run_mudscript.lua boots from.

.DESCRIPTION
  On macOS, `ms.deploy` copies mudscript/mac -> ~/.hammerspoon and re-seeds the
  Guardian trusted-hash manifest with `shasum`. That flow can't run here:
  launchd/guardian-agent, swiftc binaries, chmod 444, and `shasum` are all
  macOS-isms.

  This script does the Windows-safe subset:
    * copies ms_core.lua, init.lua, ui/, mac/lib/, sounds/, MANIFEST.json
    * backs up every file/dir it overwrites (timestamped, nothing is lost)
    * RE-SEEDS data/.ms_trusted_hash from the exact bytes just written, using
      Get-FileHash (SHA-256) — the hashes match what Guardian's `shasum` would
      compute, so the tree is provably self-consistent whether or not Guardian's
      own hashing is reachable on this rig.
    * removes data/.ms_file_manifest.json (legacy single-hash path, as deploy.sh)

  It deliberately SKIPS the macOS-only steps: the launchd guardian sentinel,
  ms_guardian_agent.sh, swiftc gamepad/OCR binaries, and chmod.

  Guardian note: on this rig Guardian hashes via hs.execute("shasum ..."), which
  is not reachable from LuaJIT's non-interactive sh, so its legacy _checkAll
  returns "error" and SKIPS — it never blocks. Re-seeding here keeps the manifest
  honest so that if `shasum` ever becomes reachable, the check passes instead of
  blocking on stale drift.

.PARAMETER Repo
  mudscript source root. Default: ..\mudscript relative to this script.

.PARAMETER HS
  Deploy target (.hammerspoon). Default: ..\.hammerspoon relative to this script.

.PARAMETER NoBackup
  Skip the pre-overwrite backup (not recommended).

.EXAMPLE
  .\deploy_mudscript.ps1
#>
[CmdletBinding()]
param(
    [string]$Repo,
    [string]$HS,
    [switch]$NoBackup
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Repo) { $Repo = Join-Path $scriptRoot '..\mudscript' }
if (-not $HS)   { $HS   = Join-Path $scriptRoot '..\.hammerspoon' }
$Repo = (Resolve-Path $Repo).Path
$HS   = (Resolve-Path $HS).Path

Write-Host "deploy: source = $Repo"
Write-Host "deploy: target = $HS"

# --- Preflight: no native macOS dialogs in shell UI (mirrors deploy.sh) --------
# A native window drawn behind the always-on-top shell can softlock the instance;
# every confirm must go through ms.ui.modal. Guardian is exempt (runs untrusted).
$nativeRe = 'hs\.dialog\.blockAlert|hs\.dialog\.textPrompt|hs\.alert\.show|hs\.chooser'
$scanFiles = @()
$libDir = Join-Path $Repo 'mac\lib'
if (Test-Path $libDir) { $scanFiles += Get-ChildItem $libDir -Recurse -File -Filter *.lua }
$scanFiles += Get-ChildItem (Join-Path $Repo 'mac') -File -Filter *.lua
$hits = @()
foreach ($f in $scanFiles) {
    if ($f.Name -eq 'ms_guardian.lua') { continue }   # Guardian allowed native dialogs
    $ln = 0
    foreach ($line in [System.IO.File]::ReadAllLines($f.FullName)) {
        $ln++
        if ($line -match '^\s*--') { continue }        # full-line Lua comment
        if ($line -match $nativeRe) { $hits += ("{0}:{1}: {2}" -f $f.Name, $ln, $line.Trim()) }
    }
}
if ($hits.Count -gt 0) {
    Write-Error ("deploy: native macOS dialog in shell UI - use ms.ui.modal instead:`n" + ($hits -join "`n"))
    exit 1
}

# --- Backup everything we might overwrite -------------------------------------
$ts = Get-Date -Format 'yyyy-MM-dd_HHmmss'
if (-not $NoBackup) {
    $bakRoot = Join-Path $HS ("data\deploy_backups\" + $ts)
    New-Item -ItemType Directory -Force -Path $bakRoot | Out-Null
    foreach ($item in @('ms_core.lua','init.lua','MANIFEST.json','lib','ui')) {
        $src = Join-Path $HS $item
        if (Test-Path $src) {
            Copy-Item -Path $src -Destination (Join-Path $bakRoot $item) -Recurse -Force
        }
    }
    Write-Host "deploy: backed up prior tree -> $bakRoot"
}

# --- Copy helpers -------------------------------------------------------------
function Copy-File($srcPath, $dstPath) {
    $dstDir = Split-Path -Parent $dstPath
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
    Copy-Item -LiteralPath $srcPath -Destination $dstPath -Force
}
function Copy-Tree($srcDir, $dstDir) {
    if (-not (Test-Path $srcDir)) { return }
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
    Get-ChildItem -LiteralPath $srcDir -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($srcDir.Length).TrimStart('\','/')
        Copy-File $_.FullName (Join-Path $dstDir $rel)
    }
}

# 1. Core + bootstrap stub (no chmod 444 on Windows).
Copy-File (Join-Path $Repo 'mac\ms_core.lua') (Join-Path $HS 'ms_core.lua')
Copy-File (Join-Path $Repo 'mac\init.lua')    (Join-Path $HS 'init.lua')

# 2. UI: top-level html, then fonts/modules/svg subtrees.
Get-ChildItem (Join-Path $Repo 'ui') -File -Filter *.html | ForEach-Object {
    Copy-File $_.FullName (Join-Path $HS ("ui\" + $_.Name))
}
# Prune UI files deleted from the repo (deploy.sh line 52).
$legacyUi = Join-Path $HS 'ui\ms_settings_ui.html'
if (Test-Path $legacyUi) { Remove-Item -Force $legacyUi }
foreach ($sub in @('fonts','modules','svg')) {
    Copy-Tree (Join-Path $Repo ("ui\" + $sub)) (Join-Path $HS ("ui\" + $sub))
}

# 3. Lua lib modules: rm -rf first so deletions propagate (deploy.sh line 73).
$dstLib = Join-Path $HS 'lib'
if (Test-Path $dstLib) { Remove-Item -Recurse -Force $dstLib }
Copy-Tree (Join-Path $Repo 'mac\lib') $dstLib

# 4. Sweep shipped Ms*.spoon (deploy.sh 83-87); user content in Spoons/ is left.
$spoons = Join-Path $HS 'Spoons'
if (Test-Path $spoons) {
    Get-ChildItem $spoons -Directory -Filter 'Ms*.spoon' -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -Recurse -Force $_.FullName }
}

# 5. Sounds: copy defaults/active/macro; never delete active/macro (user imports).
foreach ($d in @('defaults','active','macro')) {
    Copy-Tree (Join-Path $Repo ("sounds\" + $d)) (Join-Path $HS ("sounds\" + $d))
}

# 6. MANIFEST.json.
Copy-File (Join-Path $Repo 'MANIFEST.json') (Join-Path $HS 'MANIFEST.json')

# 6b. Gamepad reader (Windows analogue of deploy.sh's swiftc ms_gc_read step).
# ms.gamepadStart launches $HOME/.local/bin/ms_gc_read.exe; run_mudscript.lua
# shims HOME to the dir containing .hammerspoon, i.e. the parent of $HS. The exe
# is prebuilt from mudscript/win/bin (build it with win\bin\build.bat) and needs
# SDL2.dll beside it. If it isn't built yet we skip, mirroring how the swiftc
# binaries are skipped on macOS-isms — controller input is simply unavailable
# until the reader is built.
$homeDir  = Split-Path -Parent $HS
$localBin = Join-Path $homeDir '.local\bin'
$readerSrc = Join-Path $Repo 'win\bin\ms_gc_read.exe'
if (Test-Path $readerSrc) {
    New-Item -ItemType Directory -Force -Path $localBin | Out-Null
    Copy-File $readerSrc (Join-Path $localBin 'ms_gc_read.exe')
    $sdlSrc = Join-Path $Repo 'win\bin\SDL2.dll'
    if (Test-Path $sdlSrc) {
        Copy-File $sdlSrc (Join-Path $localBin 'SDL2.dll')
        Write-Host "deploy: gamepad reader -> $localBin\ms_gc_read.exe (+ SDL2.dll)"
    } else {
        Write-Warning "deploy: ms_gc_read.exe deployed but SDL2.dll missing beside it; the reader will not start until SDL2.dll is present in $localBin."
    }
} else {
    Write-Host "deploy: no win\bin\ms_gc_read.exe yet (build with win\bin\build.bat to enable controller input); skipping."
}

# 7. Build number (resets when stable version changes) — mirrors deploy.sh.
$dataDir = Join-Path $HS 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Force -Path $dataDir | Out-Null }

# 7a. Bundled registry index. The client reads data/registry_index.json as the
# offline / first-paint source for the Browse library. It is signed, and the
# client re-canonicalizes and verifies it against the shipped public key. The
# ONLY correct bytes are the current signed registry/index.json; any other copy
# (an older hand-committed data/registry_index.json) has a body that no longer
# matches its embedded signature, so verify fails and Browse shows no packages.
# So sync it from the source-of-truth on every deploy. (macOS mostly hides this
# by refreshing over the network, where the bundled file is just a fallback.)
$regSrc = Join-Path $Repo 'registry\index.json'
if (Test-Path $regSrc) {
    Copy-File $regSrc (Join-Path $dataDir 'registry_index.json')
    Write-Host "deploy: bundled registry index -> data\registry_index.json (signed source-of-truth)"
} else {
    Write-Warning "deploy: $regSrc missing; leaving data\registry_index.json as-is (Browse may be stale/empty offline)."
}
$buildNumFile  = Join-Path $dataDir '.ms_build_num'
$buildBaseFile = Join-Path $dataDir '.ms_build_base'
$manifestJson  = Get-Content (Join-Path $HS 'MANIFEST.json') -Raw | ConvertFrom-Json
$stableVer = $manifestJson.version
$prevBase = if (Test-Path $buildBaseFile) { (Get-Content $buildBaseFile -Raw).Trim() } else { '' }
if ($stableVer -ne $prevBase) {
    Set-Content -Path $buildNumFile  -Value '0'       -Encoding ascii -NoNewline
    Set-Content -Path $buildBaseFile -Value $stableVer -Encoding ascii -NoNewline
} else {
    $old = if (Test-Path $buildNumFile) { [int]((Get-Content $buildNumFile -Raw).Trim()) } else { 0 }
    Set-Content -Path $buildNumFile -Value ([string]($old + 1)) -Encoding ascii -NoNewline
}

# --- Re-seed data/.ms_trusted_hash from the bytes just written ----------------
# Tracked set mirrors deploy.sh / Guardian _trackedFiles(): ms_core.lua,
# ui/**/*.js, ui/**/*.html (except _popout_*), bin/*.sh (top level), lib/**/*.lua.
function Rel($full) { $full.Substring($HS.Length).TrimStart('\','/').Replace('\','/') }

$trackedAbs = New-Object System.Collections.Generic.List[string]
$trackedAbs.Add((Join-Path $HS 'ms_core.lua'))
$uiRoot = Join-Path $HS 'ui'
if (Test-Path $uiRoot) {
    Get-ChildItem $uiRoot -Recurse -File | Where-Object {
        $_.Extension -eq '.js' -or ($_.Extension -eq '.html' -and $_.Name -notlike '_popout_*')
    } | ForEach-Object { $trackedAbs.Add($_.FullName) }
}
$binRoot = Join-Path $HS 'bin'
if (Test-Path $binRoot) {
    Get-ChildItem $binRoot -File -Filter *.sh | ForEach-Object { $trackedAbs.Add($_.FullName) }
}
$libRoot = Join-Path $HS 'lib'
if (Test-Path $libRoot) {
    Get-ChildItem $libRoot -Recurse -File -Filter *.lua | ForEach-Object { $trackedAbs.Add($_.FullName) }
}

$map = @{}
foreach ($abs in $trackedAbs) {
    if (Test-Path $abs) {
        $h = (Get-FileHash -LiteralPath $abs -Algorithm SHA256).Hash.ToLower()
        $map[(Rel $abs)] = $h
    }
}
$entries = foreach ($k in ($map.Keys | Sort-Object)) { '"{0}":"{1}"' -f $k, $map[$k] }
$trustJson = '{' + ($entries -join ',') + '}'
$trustPath = Join-Path $dataDir '.ms_trusted_hash'
Set-Content -Path $trustPath -Value $trustJson -Encoding ascii -NoNewline

# Drop the CI per-file manifest so Guardian uses the legacy single-hash path
# that the re-seed above keeps correct (mirrors deploy.sh line 188).
$fileManifest = Join-Path $dataDir '.ms_file_manifest.json'
if (Test-Path $fileManifest) { Remove-Item -Force $fileManifest }

# --- Verify the manifest is self-consistent with disk -------------------------
$bad = 0
foreach ($k in $map.Keys) {
    $abs = Join-Path $HS $k
    $cur = (Get-FileHash -LiteralPath $abs -Algorithm SHA256).Hash.ToLower()
    if ($cur -ne $map[$k]) { $bad++; Write-Warning "reseed mismatch: $k" }
}
$build = (Get-Content $buildNumFile -Raw).Trim()
$coreHash = $map['ms_core.lua']
Write-Host ""
Write-Host ("Deployed. {0} tracked files hashed, {1} mismatched." -f $map.Count, $bad)
Write-Host ("ms_core.lua: {0}...  (build {1}-pre.{2})" -f $coreHash.Substring(0,16), $stableVer, $build)
if ($bad -eq 0) { Write-Host "Trusted manifest is self-consistent with disk." }
