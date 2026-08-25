-- mudspoon smoke test --
    -- The first thing to run on a Windows console after the module tree lands.
    -- The interop suite proves the pure-Lua packets against a stub host; this
    -- proves the FFI ones (foundation, C, E, G) against the real Win32 that a
    -- stub can't stand in for: that the low-level keyboard hook actually
    -- installs, that a chord both FIRES a callback and SWALLOWS the key so the
    -- focused window never sees it, and that teardown releases the hook so the
    -- process exits without leaving the OS holding a stale WH_KEYBOARD_LL.
    --
    -- Physical console, foreground, NOT over RDP. RDP intercepts input and
    -- misreports hooks (see README). If this passes there, foundation stands up.
    --
    --   luajit smoke.lua
    --
    -- Press Ctrl+Alt+K in any window. Expected:
    --   * "[smoke] chord fired" prints here.
    --   * the K does NOT appear in the focused window (swallowed).
    --   * the process exits 0 within a few seconds of the press.
    -- If 30s pass with no press, it exits 1 as "hook may not be installed".
-- END --

-- Resolve requires from this script's own directory, whatever the cwd is.
    local here = (arg[0] or "smoke.lua"):gsub("[^/\\]*$", "")
    if here == "" then here = "./" end
    package.path = here .. "?.lua;" .. here .. "?/init.lua;" .. package.path

local hs = require("hs")

-- Fail loud if the FFI packets didn't load (interop can't catch a bad cdef).
    assert(hs.hotkey,   "[smoke] hs.hotkey missing (packet F / eventtap / keycodes)")
    assert(hs.eventtap, "[smoke] hs.eventtap missing (packet B)")
    assert(hs.timer,    "[smoke] hs.timer missing (packet A)")

print("[smoke] modules loaded. press Ctrl+Alt+K on the physical console...")

local fired = false

-- The one chord under test. If the key reaches this callback, the hook is
-- installed and dispatch works; returning from it (swallow is the tap's job)
-- leaves the key consumed, which we confirm by watching the focused window.
hs.hotkey.bind({ "ctrl", "alt" }, "k", function()
    fired = true
    print("[smoke] chord fired  (K should NOT have reached the focused window)")
    hs.hotkey.disableAll()   -- exercise teardown: last hotkey gone -> tap stops
    hs.shutdown()            -- release the hook, then let run() return
end)

-- Watchdog: never wedge the console. If nothing is pressed, tear down and fail.
hs.timer.doAfter(30, function()
    if not fired then
        io.stderr:write("[smoke] TIMEOUT: no chord in 30s. hook may not be installed,\n")
        io.stderr:write("        or you are over RDP, or another hook swallowed it first.\n")
        hs.shutdown()
    end
end)

hs.run()

-- run() returns only after shutdown(). Exit code carries the verdict so a
-- wrapper (or your eyes) gets a clean pass/fail.
if fired then
    print("[smoke] PASS: hook installed, chord fired, teardown clean.")
    os.exit(0)
else
    os.exit(1)
end
