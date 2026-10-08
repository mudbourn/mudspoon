# mudspoon

A Hammerspoon compatibility layer for Windows. A standalone LuaJIT host
implements the `hs.*` API through FFI calls to `user32`, `kernel32` and `gdi32`,
so tools written against Hammerspoon run unmodified on Windows. mudscript is the
first consumer.

`mudspoon` is only the repo codename. At runtime the host presents itself as
Hammerspoon: process identity (`hs.processInfo.bundleID`), window classes
(`HammerspoonWebView`, `HammerspoonCanvas`, `HammerspoonAlert`), the boot log
(`hammerspoon.log`) and log tags. Tools that probe for Hammerspoon see it.

The host runs at a physical console session. RDP intercepts input and
misreports the low-level hooks.

## Layout

- `run_mudscript.lua`: the host glue that Hammerspoon.app normally provides. It
  builds `hs`, sets `HOME` to the folder that holds `.hammerspoon`, and runs
  mudscript's `init.lua` on the foundation runloop.
- `hs/`: one module per `hs.*` extension. `hs/foundation.lua` owns the Win32
  message pump, the timer scheduler, the low-level keyboard and mouse hooks and
  the clock.
- `launch.ps1`, `stop.ps1`, `watchdog.ps1`, `tray.ps1`: start, stop and guard the
  windowless host.
- `hs.cmd`: the `hs` command line client for the `hs.ipc` endpoint.
- `installer/`: the Inno Setup installer.
- `test/`: the smoke and parity suite.

`CONTRIBUTING.md` holds the module contracts and `WRITING_STYLE.md` the style
rules.

## Installing

`installer\build.ps1` stages the host, LuaJIT and a deployed copy of mudscript,
then compiles `installer\Output\Mudspoon-Setup.exe` with Inno Setup 6.

```
powershell -ExecutionPolicy Bypass -File installer\build.ps1
```

The installer puts everything under `%LOCALAPPDATA%\Mudspoon`:

- `app\`: the host, LuaJIT and the launch scripts.
- `.hammerspoon\`: the mudscript config the host boots from. User data in
  `.hammerspoon\data` survives updates and uninstall.

## Running

Double-click `Mudspoon.cmd`. On first run `launch.ps1` installs anything missing
with winget: LuaJIT and the VC++ runtime, the WebView2 runtime that draws every
UI window, and Git for Windows as a POSIX shell. It then starts the host
windowless and detached, with the watchdog beside it.

| Flag | Effect |
| --- | --- |
| `-Foreground` | Run attached and stream the boot log. Ctrl+C stops it. |
| `-NoWebview` | Headless macro host with no WebView2 UI. |
| `-SkipDeps` | Skip the dependency preflight. |
| `-NoGlass` | Draw webviews on layered windows instead of DWM glass windows. |
| `-Dev` | Start the `hs.ipc` endpoint for `hs.cmd`. |

`Stop-Mudspoon.cmd` quits the windowless host. The tray icon, which stays in the notification area whether or not the host runs, can also start, restart and stop it.

With `-Dev`, `hs.cmd` sends Lua to the running host and prints the result:

```
hs.cmd -c "print(hs.configdir)"
```

From a checkout, the host boots the sibling `..\.hammerspoon`.
`deploy_mudscript.ps1` copies the mudscript source into that tree and re-seeds
the Guardian trusted hash.

## Setup from a checkout

`setup.ps1` installs LuaJIT with winget and pins it to `C:\tools\luajit`.

```
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

`setup.sh` builds LuaJIT from source with MSVC in Git Bash, for machines
without winget.

## Testing

`test\smoke.lua` runs unchanged under real Hammerspoon and mudspoon.
`test\smoke_win.ps1` and `test\smoke_mac.sh` run it on each platform and
`test\diff_smoke.lua` compares the two reports. `test\README.md` has the details.

The top-level `spike_*.lua`, `smoke*.lua` and `probe_hook.lua` are the first
exercises of the FFI architecture.

## Known limits

- The host is unsigned. A background process with a global keyboard hook can be
  flagged by antivirus and SmartScreen.
- The host runs at user level. A game running elevated needs the host run as
  administrator to receive its input.
