# mudspoon - Hammerspoon for Windows

A Hammerspoon compatibility layer for Windows. A standalone Lua 5.4 host
implements the `hs.*` API through FFI calls to `user32`, `kernel32` and `gdi32`,
so tools written against Hammerspoon run unmodified on Windows.

`mudspoon` is only the repo codename. At runtime the host presents itself as
Hammerspoon: process identity (`hs.processInfo.bundleID`), window classes
(`HammerspoonWebView`, `HammerspoonCanvas`, `HammerspoonAlert`), the boot log
(`hammerspoon.log`) and log tags. Tools that probe for Hammerspoon see it.

The host runs at a physical console session. RDP intercepts input and
misreports the low-level hooks.

## Install

In PowerShell:

```
irm https://raw.githubusercontent.com/mudbourn/mudscript/main/win/install.ps1 | iex
```

This installs Hammerspoon for Windows and mudscript for the current user and
adds Start menu shortcuts. Running it again updates both or uninstalls them.
Each release also carries `Mudspoon.zip`, the app folder on its own.

## Layout

- `main.lua`: the host glue that Hammerspoon.app normally provides. It builds
  `hs`, sets `HOME` from `USERPROFILE` when unset, and runs
  `%USERPROFILE%\.hammerspoon\init.lua` on the foundation runloop. The first
  command-line argument or `MUDSPOON_CONFIG_DIR` overrides the config folder.
- `hs/`: one module per `hs.*` extension. `hs/foundation.lua` owns the Win32
  message pump, the timer scheduler, the low-level keyboard and mouse hooks and
  the clock.
- `launch.ps1`, `stop.ps1`, `watchdog.ps1`, `tray.ps1`: start, stop and guard the
  windowless host.
- `hs.cmd`: the `hs` command line client for the `hs.ipc` endpoint.
- `installer/`: `build.ps1`, which packages the app as `Mudspoon.zip`.
- `test/`: the smoke and parity suite.

`CONTRIBUTING.md` holds the module contracts and `WRITING_STYLE.md` the style
rules.

## Installing

`installer\build.ps1` stages the host and the Lua runtime, then packs them into `installer\Output\Mudspoon.zip`.

```
powershell -ExecutionPolicy Bypass -File installer\build.ps1
```

The install script puts the app under `%LOCALAPPDATA%\Mudspoon\app`: the host, the
Lua runtime and the launch scripts. The config lives in `%USERPROFILE%\.hammerspoon`
and is never touched by install or uninstall.

## Running

Double-click `Mudspoon.cmd`. On first run `launch.ps1` installs anything missing
with winget: the WebView2 runtime that draws every UI window, and Git for
Windows as a POSIX shell. It then starts the host
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

The host boots `%USERPROFILE%\.hammerspoon\init.lua`. The host also writes
`hammerspoon.log`, `.hs_heartbeat` and `data\` there.

## Setup from a checkout

`setup.ps1` checks the Lua runtime in `runtime\` and loads its `ffi` module.

```
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

`setup.sh` rebuilds `runtime\` from source in Git Bash with a MinGW-w64 toolchain.
It builds Lua 5.4.7, libffi 3.4.6 and cffi-lua, patched by
`runtime\cffi-lua.patch`.

## Runtime

`runtime\lua.exe` is stock Lua 5.4 and `runtime\cffi.dll` is cffi-lua, which
provides the `ffi` module. `compat\ffi.lua` is what `require("ffi")` loads. It
returns cffi-lua and makes `tonumber` read 64-bit cdata. The patch makes a NULL
pointer read as `nil` and an unsigned 64-bit value that fits in 63 bits read as
a Lua integer. Every launcher starts the host as `runtime\lua.exe -E`.

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

## License

[MIT](LICENSE)
