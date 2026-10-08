# Shim parity audit — 2026-08-27

Usage-driven audit of Windows shims (`Main/hs/`) against real Hammerspoon
(`reference/hammerspoon/extensions/`) restricted to paths mudscript
(`mudscript/mac/`) actually exercises. Method: grep mac/ call sites, diff only
those against upstream + shim. Tags: **pile-1** = real parity gap on an
unexercised path (dormant); **pile-2** = mudscript-side glue bug; **pile-3** =
real parity gap on an exercised path (LIVE).

## Pile ratio (7 modules)

| Module | pile-1 | pile-2 | pile-3 |
|---|---|---|---|
| menubar | 6 | 1 | 0 |
| eventtap | 1 | 1 | 3 |
| window | 3 | 1 | 1 |
| application | 3 | 1 | 1 |
| timer | 2 | 0 | 0 |
| canvas | 2 | 0 | 0 |
| webview | 3 | 1 | 2 |
| **total** | **20** | **5** | **7** |

**Heuristic:** live gaps track *contract-shape surface and COM/vtable/stub
complexity*, NOT call traffic. timer (144 `doAfter` calls) is parity-clean;
webview (a handful of calls) has 2 live gaps. The JIT "bad callback" scar is a
non-issue on every exercised path — timer never registers an FFI callback,
canvas follows the `jit.off(wndProc)` + kept-cast pattern, and the real fix is
`jit.off(host.run)` on the pump (`foundation.lua:498-505`).

## LIVE gaps (pile-3), triaged least-obvious → most-worth-fixing-first

1. **eventtap `keyboardEventAutorepeat` is derived, not native** -- the
   low-level hook gives no repeat flag, so `foundation.lua` marks a hardware
   keyDown as autorepeat when its vk is already held without a keyUp. Injected
   events are tracked in a separate set and never count as hardware repeats, so a
   synthetic keyUp does not make the next hardware repeat look like a fresh press.
   Panic releases both sets.
2. **application `:name()` caches transient failure permanently** —
   `application.lua:87-92`: `self._name = b or false`, returns `_name or nil`
   forever. One `imagePath` race strands name at nil; name is the app-resolution
   key (`ms_core.lua:864`-style, `951`).
3. **eventtap `newMouseEvent(2/4/26, pos)` throws every call** — mac passes
   upstream integer CGEventType (`ms_core.lua:447-451`); shim `MOUSE_FLAGS` keys
   are strings (`event.lua:187-260`) → `error("cannot post event of type '2'")`,
   pcall-swallowed → startup "release stuck mouse buttons" pass never releases.
4. **window.filter is a `STUB_MODULES` black-hole** — no `hs/window/filter.lua`;
   `run_mudscript.lua:333`. mac subscribes at `ms_core.lua:5858-5910` (macro
   window move/resize recorder) → recording silently captures nothing.
   Surface needed: `.new(nil)`, `.windowMoved` (req) / `.windowsChanged` (opt,
   guarded), `wf:getWindows()`, `wf:subscribe(events,cb)`, `wf:unsubscribeAll()`;
   window objs need `:application():name()`, `:id()`, `:frame()`.
5. **application.watcher is a no-op** — `application.lua:247-266` `:start()`
   returns self, callback never fires. mac at `ms_core.lua:2252` (auto-retarget
   on activation) and `ms_devtools.lua:2184-2201` (dev tracker) → never react to
   foreground changes. Upstream is a real event source (`SetWinEventHook` needed).
6. **webview `navigationCallback` unimplemented, throws UNGUARDED** — no such
   method; `NavigationCompleted` vtable slot left as padding (`webview.lua:254`).
   Unguarded call sites throw `attempt to call method 'navigationCallback'
   (a nil value)` and abort: `ms_settings.lua:4764`, `ms_devtools.lua:1370`.
   (Guarded/benign: `ms_shell.lua:1357`, `ms_guardian.lua:811`.) Only LOUD gap.
7. **webview `:html(str, baseURL)` drops baseURL** — `webview.lua:564` uses
   WebView2 `NavigateToString` (no base doc), ignores 2nd arg. baseURL passed at
   every site incl. load-bearing `ms_loading.lua:116`, `ms_shell.lua:499`.
   Relative CSS/JS/img/font won't resolve. Blast radius gated on whether shell/
   loading templates inline vs reference relative assets — needs a template check.

## Notable pile-2 (glue bugs worth fixing alongside)

- **window `:frame()` zero-rect masquerade** — `window.lua:139-144` returns
  `{0,0,0,0}` on `GetWindowRect` failure; `:isStandard()` hardcoded `true`
  (`163-165`). Consumed by centering math (`ms_core.lua:1850,2088,2164`;
  `ms_devtools.lua:2030`) → silent wrong positions instead of an error.
- **eventtap stale contract comment** — `event.lua:296-307` claims foundation
  doesn't emit `flagsChanged`/`*Dragged`; it now does (`foundation.lua:368,416-419`).
  Harmless, misleading.

## Dormant (pile-1) — do NOT fix unless a caller starts exercising them

eventtap: `tap.lua:47` swallows only literal `true` (upstream any truthy).
window: `find` substring vs Lua patterns; `orderedWindows`=`allWindows` (no
Z-order); `allWindows` visible+title heuristic vs style-bit standard-windows.
application: `find`=`get` (single vs list); `get` only sees windowed processes;
`:kill/:hide/:unhide` no-ops. canvas: track-flags ignored (id-keyed hitTest
happens to work); `:behavior()` no-op. webview: `:hswindow()/:behavior()` nil
(all sites pcall-guarded). timer: repeating-timer-survives-error (safer than
upstream); `:fire()` doesn't reschedule.

## Not gaps (verified fine / deliberate)

`hs.focus` implemented today (`hs/focus.lua`). `hs.chooser` in STUB_MODULES but
zero call sites — deploy.sh forbids native chooser (draws behind webview shell).
`hs.loadSpoon`/`hs.openConsole` cosmetic pcall-wrapped no-ops. `hs.webview*` real
(only stubbed in no-webview boot path).
