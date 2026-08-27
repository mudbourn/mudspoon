# mudspoon

A Hammerspoon compatibility layer for Windows. A standalone LuaJIT host that
implements the `hs.*` API surface so tools written against Hammerspoon run
unmodified on Windows, with mudscript as the first consumer. Closer in spirit to
Proton or FEX than to a per-app port.

Codename `mudspoon` is provisional and only appears in the alert window class today.

## Status: spike stage

No module tree, no WebView2, no Guardian, no signing yet. One file carries the
whole thesis: that real Lua can drive Win32 through FFI well enough to replace
Hammerspoon.

### `spike_hook_loop_alert.lua`

Three legs in one single-threaded process:

1. A global keyboard hook (`WH_KEYBOARD_LL`) via FFI, which intercepts rather than
   only observes.
2. The event loop. A Win32 message pump married to a Lua timer scheduler on one
   thread (`MsgWaitForMultipleObjects`). Every future `hs.timer`, `hs.eventtap`, and
   alert animation hangs off this. macOS gives Hammerspoon the same thing through its
   runloop.
3. A native layered alert window (rounded rect, text, alpha fade) driven by leg 2.
   The `hs.canvas` and `ms_alert` replacement, without antialiasing or hit-testing.

`Ctrl+Alt+K` popping a fading alert and swallowing the K means the architecture holds.

## Running mudscript (one click)

The Windows equivalent of double-clicking `Hammerspoon.app`. mudspoon is the host;
mudscript is the config it loads from the sibling `../.hammerspoon`.

**Double-click `Mudspoon.cmd`.**

On first run it auto-installs whatever is missing via winget — LuaJIT (+ the VC++
runtime), the WebView2 runtime (the shell and loading screens are WebView2, and are
invisible without it), and a POSIX shell (Git for Windows) for mac/'s file ops — then
boots the host **windowless and detached**, so it keeps running after the launcher
window closes. Later launches skip straight past the checks.

- `Mudspoon.cmd -Foreground` — run attached, streaming the boot log (Ctrl+C stops it).
- `Mudspoon.cmd -NoWebview` — headless macro host, no WebView2 UI.
- `Mudspoon.cmd -SkipDeps` — fastest re-launch, skip the dependency preflight.
- `Stop-Mudspoon.cmd` — quit the windowless host from outside (its menubar quit also works).

The launcher (`launch.ps1`) also sets `MUDSPOON_WEBVIEW=1` and puts the bundled
`WebView2Loader.dll` on the DLL search path — the two steps that were previously
manual and, if forgotten, left the whole UI invisible. Still a physical console
session, not RDP: RDP intercepts input and misreports the low-level hooks.

## Running the spikes / smoke tests

On the Windows PC, at the physical console, foreground, not over RDP. RDP intercepts
input and misreports hooks.

Needs only `luajit.exe`. No C compiler and no `winapi` module. FFI calls
`user32`, `kernel32`, and `gdi32` directly.

Get LuaJIT installed and on PATH on a bare rig with the PowerShell setup. It
installs via winget, pins the binary to `C:\tools\luajit`, fixes PATH, and
verifies.

```
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

Then run the spike:

```
luajit spike_hook_loop_alert.lua
```

`setup.sh` remains as a from-source build (LuaJIT via MSVC in Git Bash) for rigs
without winget.

- `Ctrl+Alt+K` pops a native alert and swallows the K keystroke.
- `Ctrl+Alt+Q` quits.

### First run of the module tree

The spike is one file of raw FFI. The `hs/` tree is the rewrite, and its FFI
packets (foundation, C, E, G) have only been compile- and logic-checked — no
Win32 behaviour of theirs has run yet. `smoke.lua` is the first exercise of it:
it loads `hs`, binds one hotkey, and runs the loop. Same console rules as the
spike (physical, foreground, not RDP).

```
luajit smoke.lua
```

Press `Ctrl+Alt+K`. It passes (exit 0) if the chord fires, the `K` never reaches
the focused window (swallowed), and the process exits cleanly. It fails (exit 1)
if 30s pass with no chord — the hook likely never installed.

## Open before this reaches another machine

Not blocking the spike.

1. Code signing and SmartScreen. An unsigned background process installing a global
   keyboard hook is the exact profile AV heuristics flag. Budget a certificate and
   plain "why did Windows flag this" messaging before first release.
2. Integrity-level matching. Elevated games need the host run as admin to be hookable.
   Ship user-level and document it, the pattern AHK uses today.
3. Guardian redesign and self-update. Direction is picked, design pass is owed.

Full reasoning lives in the Obsidian plan `Mudscript Windows.md`.
