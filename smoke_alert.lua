-- mudspoon alert-substrate smoke --
    -- Exercises hs/alert/window.lua (Task A) ALONE, before the hs.alert policy
    -- layer (Task B) exists. It drives the substrate directly through its frozen
    -- contract -- show(text, rect) -> handle, handle:setAlpha, handle:close -- so
    -- the GDI/window mechanics are proven on real Win32 independently of B.
    --
    -- Physical console (a layered top-most window needs the interactive desktop).
    --
    --   luajit smoke_alert.lua
    --
    -- Expected: a rounded dark pill with centred text appears near the bottom-right
    -- of the primary screen, fades smoothly to invisible over ~1s, then the process
    -- exits 0. Nothing to press. A 10s watchdog fails loud if the loop wedges.
    --
    -- This is a SEE-IT test: the pass is your eyes confirming a clean rounded,
    -- centred, fading pill. The script only asserts that show() returned a handle
    -- and the sequence ran without a Win32/FFI error.
-- END --

-- Resolve requires from this script's own directory. --
    local here = (arg[0] or "smoke_alert.lua"):gsub("[^/\\]*$", "")
    if here == "" then here = "./" end
    package.path = here .. "?.lua;" .. here .. "?/init.lua;" .. package.path
-- END --

local hs     = require("hs")
local window = require("hs.alert.window")

assert(hs.screen, "[smoke_alert] hs.screen missing (needed to place the window)")
assert(hs.timer,  "[smoke_alert] hs.timer missing (needed to drive the fade)")

-- Place a 360x96 pill near the bottom-right of the primary work area. --
    local f = hs.screen.primaryScreen():frame()
    local w, h = 360, 96
    local rect = { x = f.x + f.w - w - 24, y = f.y + f.h - h - 32, w = w, h = h, alpha = 255 }
-- END --

print("[smoke_alert] showing pill; it should fade out over ~1s...")

local ok, handleOrErr = pcall(window.show, "mudspoon alert substrate", rect)
if not ok then
    io.stderr:write("[smoke_alert] FAIL: window.show errored: " .. tostring(handleOrErr) .. "\n")
    os.exit(1)
end
local handle = handleOrErr

local passed = false

-- Fade off the runloop: step alpha down every 40ms, close at the bottom. --
    local alpha = 255
    local function fade()
        alpha = alpha - 20
        if alpha <= 0 then
            handle:close()
            handle:close()          -- prove close() is idempotent (no crash on 2nd)
            passed = true
            hs.stop()
            return
        end
        handle:setAlpha(alpha)
        hs.timer.doAfter(0.04, fade)
    end
    -- Hold fully opaque briefly so the pill is legible before it starts fading.
    hs.timer.doAfter(0.6, fade)
-- END --

-- Watchdog: never wedge the console if the loop stalls. --
    hs.timer.doAfter(10, function()
        if not passed then
            io.stderr:write("[smoke_alert] TIMEOUT: fade never completed in 10s.\n")
            handle:close()
            hs.stop()
        end
    end)
-- END --

hs.run()

if passed then
    print("[smoke_alert] PASS: pill shown, faded, closed (idempotent) with no Win32 error.")
    os.exit(0)
else
    io.stderr:write("[smoke_alert] INCOMPLETE: fade did not finish.\n")
    os.exit(1)
end
