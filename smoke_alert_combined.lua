-- mudspoon combined alert smoke (policy + substrate, real Win32) --
    -- Proves the FULL stack: hs.alert (Task B policy -- sizing, centering, stacking,
    -- fades, registry) driving hs.alert.window (Task A GDI substrate) over
    -- foundation's one runloop. The companion smoke_alert.lua exercises the
    -- substrate alone; this one goes through hs.alert.show, the public seam.
    --
    -- Physical console, foreground, NOT over RDP (layered top-most windows need the
    -- interactive desktop; RDP misreports).
    --
    --   luajit smoke_alert_combined.lua
    --
    -- SEE-IT test: the pass is your eyes confirming three pills fade in and stack
    -- top-to-bottom, a styled amber pill pops a beat later, all fade out on their
    -- own, then two long-lived pills clear early via closeAll. The script asserts
    -- the sequence ran with no Win32/FFI error and the runloop torn down cleanly.
    -- A 12s watchdog fails loud if the loop wedges.
-- END --

-- Resolve requires from this script's own directory (matches smoke_alert.lua). --
    local here = (arg[0] or "smoke_alert_combined.lua"):gsub("[^/\\]*$", "")
    if here == "" then here = "./" end
    package.path = here .. "?.lua;" .. here .. "?/init.lua;" .. package.path
-- END --

local host  = require("hs.foundation")
local alert = require("hs.alert")       -- not on the frozen hs namespace; required directly
local timer = require("hs.timer")

print("[smoke_alert_combined] starting full-stack alert run...")

local errored = false
local function guard(label, fn)
    local ok, err = pcall(fn)
    if not ok then
        errored = true
        io.stderr:write("[smoke_alert_combined] FAIL (" .. label .. "): " .. tostring(err) .. "\n")
    end
end

-- Three alerts with overlapping lifetimes -> exercises stacking + registry. --
    guard("initial stack", function()
        alert.show("mudspoon alert one")
        alert.show("second alert, stacked below")
        alert.show("third, a longer line to check width sizing")
    end)
-- END --

-- A styled, custom-duration alert a beat later. --
    timer.doAfter(0.8, function()
        guard("styled show", function()
            alert.show("styled alert (amber on black)", {
                fillColor = 0x00000000,   -- black   (COLORREF 0x00BBGGRR)
                textColor = 0x0000A5FF,   -- amber
                textSize  = 24,
            }, 1.5)
        end)
        print("[smoke_alert_combined] styled alert shown")
    end)
-- END --

-- Two long-lived alerts we cancel early -> fade-mid-life + closeAll drain. --
    timer.doAfter(2.0, function()
        guard("long-lived show", function()
            alert.show("long-lived A (closeAll target)", nil, 60)
            alert.show("long-lived B (closeAll target)", nil, 60)
        end)
        print("[smoke_alert_combined] two long-lived alerts shown")
    end)

    timer.doAfter(3.5, function()
        guard("closeAll", function() alert.closeAll() end)
        print("[smoke_alert_combined] closeAll fired")
    end)
-- END --

-- Let every fade finish, then tear the runloop + hooks down cleanly. --
    timer.doAfter(6.0, function()
        print("[smoke_alert_combined] sequence complete; shutting down.")
        host.shutdown()
    end)
-- END --

-- Watchdog: never wedge the console if the loop stalls. --
    timer.doAfter(12, function()
        io.stderr:write("[smoke_alert_combined] TIMEOUT: run did not complete in 12s.\n")
        host.shutdown()
    end)
-- END --

host.run()

if errored then
    io.stderr:write("[smoke_alert_combined] INCOMPLETE: a Win32/FFI error occurred above.\n")
    os.exit(1)
end
print("[smoke_alert_combined] PASS: shown, stacked, styled, faded, closeAll'd; runloop clean.")
os.exit(0)
