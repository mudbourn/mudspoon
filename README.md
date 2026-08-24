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

## Running

On the Windows PC, at the physical console, foreground, not over RDP. RDP intercepts
input and misreports hooks.

Needs only `luajit.exe`. No C compiler and no `winapi` module. FFI calls
`user32`, `kernel32`, and `gdi32` directly.

```
luajit spike_hook_loop_alert.lua
```

- `Ctrl+Alt+K` pops a native alert and swallows the K keystroke.
- `Ctrl+Alt+Q` quits.

## Open before this reaches another machine

Not blocking the spike.

1. Code signing and SmartScreen. An unsigned background process installing a global
   keyboard hook is the exact profile AV heuristics flag. Budget a certificate and
   plain "why did Windows flag this" messaging before first release.
2. Integrity-level matching. Elevated games need the host run as admin to be hookable.
   Ship user-level and document it, the pattern AHK uses today.
3. Guardian redesign and self-update. Direction is picked, design pass is owed.

Full reasoning lives in the Obsidian plan `Mudscript Windows.md`.
