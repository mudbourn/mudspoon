# Contributing to the `hs.*` port

The `hs.*` surface is built as independent work packets that each own their own
files. This note is the whole coordination surface: the dependency order, the
three frozen contracts every packet codes against, and the shared rules. Read it
before touching a module.

## The one substrate: `hs.foundation`

`hs/foundation.lua` is built and frozen. It owns the parts that must be singular:

- **The runloop.** One Win32 message pump married to one Lua timer scheduler on
  one thread (`MsgWaitForMultipleObjects`). `host.run()` blocks until
  `host.stop()`; `host.shutdown()` also releases the hooks.
- **The hooks.** One `WH_KEYBOARD_LL` and one `WH_MOUSE_LL`, installed lazily on
  first subscription and removed on last, fanned out through host dispatch.
- **The event object.** Constructed here so the read and post sides share one
  shape (see contract 1).
- **The clock and scheduler core.** `host.now()` (monotonic ms via QPC) and
  `host.schedule(delayMs, fn, intervalMs?)` — what `hs.timer` wraps.
- **All shared Win32 typedefs.** LuaJIT errors on a duplicate `typedef`, so base
  types are declared exactly once, in foundation. Your module `ffi.cdef`s only
  the **functions** it calls (and any function-pointer typedef unique to it).

## Work packets

| Packet | Module | Owns | Win32 primitives | Depends on |
|--------|--------|------|------------------|------------|
| A | `hs.timer` | `hs/timer.lua` | scheduler core / QPC | Foundation |
| B | `hs.eventtap` (read) | `hs/eventtap/tap.lua` | `host.onKey`/`host.onMouse` | Foundation + contract 1 |
| C | `hs.eventtap.event` (post) | `hs/eventtap/event.lua` | `SendInput` | Foundation + contracts 1 & 2 |
| D | `hs.keycodes` | `hs/keycodes.lua` | static VK table | none (leaf) |
| E | `hs.mouse` | `hs/mouse.lua` | `GetCursorPos`/`SetCursorPos` | Foundation (+ G stub) |
| F | `hs.hotkey` | `hs/hotkey.lua` | chord match over B | B + D |
| G | `hs.screen` | `hs/screen.lua` | `EnumDisplayMonitors`/`GetSystemMetrics` | Foundation |

**Start now, fully parallel:** A, B, D, E, G. C can start too — contract 1 is
frozen. F is the only downstream packet; take it once B and D exist (or mock
them against the contracts below).

`hs/init.lua` is frozen and is the only place modules are assembled into the `hs`
namespace. A missing module is skipped, so the tree runs as packets land — you do
not edit init.lua to plug your module in.

## The three frozen contracts

### 1. The event object (produced by B, produced+posted by C, consumed by F)

Construct every event through `host.newEvent(spec)`. One shape, one metatable.

```lua
local ev = host.newEvent{
  type    = "keyDown",   -- e.g. keyDown/keyUp, leftMouseDown, mouseMoved, scrollWheel
  keyCode = 0x4B,        -- virtual-key code; nil for mouse events
  flags   = { ctrl = true, alt = true },  -- set-table, truthy keys only:
                                          -- ctrl, alt, shift, cmd (cmd = Win key)
  props   = { scanCode = 37 },            -- extra read-only fields
}
```

Read side (all present today):

- `ev:getType()` → string
- `ev:getKeyCode()` → number
- `ev:getFlags()` → the flags set-table
- `ev:getProperty(k)` → a `props` field (`x`, `y`, `scanCode`, `mouseData`,
  `buttonNumber`, `injected`, `extra`)

Post side: **C** implements `ev:post()` by assigning to `host.eventProto.post`
(the shared prototype). Until C is loaded, `:post()` errors. C stamps
`host.INJECTED_MAGIC` into the event's `dwExtraInfo`; the read side sees it back
as `ev:getProperty("extra")`, so a packet can ignore its own injected events.

### 2. `hs.keycodes.map` (D)

Bidirectional, matching Hammerspoon: `map[name] → code` **and** `map[code] →
name` — a plain table, not callable (as in real Hammerspoon). For explicit
lookups use `hs.keycodes.keyCodeForName(name)` / `nameForKeyCode(code)`. Codes are
Windows virtual-key codes (what the event object's `getKeyCode()` returns);
names are the Hammerspoon names so scripts port unchanged. Note `"fn"` has no
Win32 code and is intentionally absent — do not rely on it.

### 3. Host dispatch (foundation, consumed by B and F)

- `host.onKey(fn)` / `host.onMouse(fn)` → an **unsubscribe** function. Call it to
  remove the handler; the hook uninstalls when the last one leaves.
- `fn` receives an event object. **Return `true` to swallow** — the OS never sees
  the event and later subscribers do not run.

## Shared rules

- **Keep FFI callbacks alive.** Any `ffi.cast(...)` used as a callback must be
  held in a module-level reference for its whole life. A collected callback is a
  hard crash. (Foundation already does this for the hooks.)
- **No module runs its own message loop or installs its own hook.** Register with
  `host.onKey` / `host.onMouse` / `host.schedule`.
- **No module re-`typedef`s a shared type.** `ffi.cdef` only your functions.
- **Each module returns a table.** Only `hs/init.lua` wires it into `hs`.
- **Errors in handlers must not kill the loop.** Foundation `pcall`s dispatch and
  timer callbacks; keep your own callbacks from throwing across the FFI boundary.
