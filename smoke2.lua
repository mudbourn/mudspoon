-- mudspoon smoke test 2 -- the "exercise the rest" pass --
    -- smoke.lua proved ONE slice on real Win32: the low-level keyboard hook
    -- installs, a chord fires and swallows, teardown releases it. Three coded
    -- modules were still UNEXERCISED after that run -- they compiled and bound
    -- their cdefs, but no key had ever been read back out of real hardware.
    -- This is that run: it drives the three against live Win32.
    --
    --   * screen  (Thread G)  EnumDisplayMonitors -> monitor geometry
    --   * mouse   (Thread E)  Get/SetCursorPos + button state
    --   * inject  (Thread C)  SendInput, proven by ROUND-TRIP: an event this
    --                         process injects must come back through this
    --                         process's own hook flagged injected, carrying the
    --                         INJECTED_MAGIC we stamped, and get swallowed so the
    --                         focused window never sees it.
    --
    -- Physical console, foreground, NOT over RDP -- same rule as smoke.lua. The
    -- injection round-trip in particular depends on the LL hook seeing our own
    -- SendInput, which RDP misreports.
    --
    --   luajit smoke2.lua
    --
    -- Expected: three checks print PASS, the cursor jumps once to screen centre
    -- and jumps back, no F13 leaks to the focused window, process exits 0. On any
    -- failure it prints which check failed and exits 1. A 15s watchdog fails loud
    -- rather than wedging the console if injection never round-trips.
-- END --

-- Resolve requires from this script's own directory, whatever the cwd is. --
    local here = (arg[0] or "smoke2.lua"):gsub("[^/\\]*$", "")
    if here == "" then here = "./" end
    package.path = here .. "?.lua;" .. here .. "?/init.lua;" .. package.path
-- END --

local hs = require("hs")

-- Fail loud if any packet under test didn't load (a bad cdef surfaces here). --
    assert(hs.screen,        "[smoke2] hs.screen missing (packet G)")
    assert(hs.mouse,         "[smoke2] hs.mouse missing (packet E)")
    assert(hs.eventtap,      "[smoke2] hs.eventtap missing (packet B)")
    assert(hs.eventtap.event,"[smoke2] hs.eventtap.event missing (packet C / SendInput)")
    assert(hs.timer,         "[smoke2] hs.timer missing (packet A)")
-- END --

-- Verdict tracking: every check must flip its slot to true to pass. --
    local checks = { screen = false, mouse = false, inject = false }

    local function fail(msg)
        io.stderr:write("[smoke2] FAIL: " .. msg .. "\n")
        hs.shutdown()      -- release any hook; let run() return so we exit 1
    end
-- END --

print("[smoke2] modules loaded. running screen + mouse synchronously...")

-- Check 1: screen enumeration (synchronous -- no runloop needed) --
    -- allScreens() must yield at least one display with a sane frame, and exactly
    -- one must report primary. Print the geometry so a human can eyeball it against
    -- the actual monitor layout -- a fallbackScreen() masquerade (session 0 / no
    -- EnumDisplayMonitors) would show a single 0,0-anchored screen named DISPLAY1.
    do
        local all = hs.screen.allScreens()
        if #all == 0 then fail("hs.screen.allScreens() returned no monitors"); return end

        local primaries = 0
        for i, s in ipairs(all) do
            local f = s:fullFrame()
            local ok = f.w > 0 and f.h > 0
            print(string.format("[smoke2]   screen %d: %s  full=%d,%d %dx%d  primary=%s%s",
                i, s:name(), f.x, f.y, f.w, f.h, tostring(s.primary), ok and "" or "  <-- BAD FRAME"))
            if not ok then fail("screen " .. i .. " has a non-positive frame"); return end
            if s.primary then primaries = primaries + 1 end
        end

        if primaries ~= 1 then
            fail("expected exactly one primary screen, found " .. primaries); return
        end

        checks.screen = true
        print("[smoke2] PASS screen: " .. #all .. " monitor(s), one primary.")
    end
-- END --

-- Check 2: cursor read + set round-trip (synchronous) --
    -- Read the real cursor, move it to the primary screen's centre, read it back,
    -- and confirm it landed within tolerance -- then restore the original position
    -- so the run is non-destructive. Tolerance absorbs DPI/virtualisation rounding;
    -- SetCursorPos is normally exact but scaled desktops can shift a pixel or two.
    do
        local TOL = 4  -- pixels

        local start = hs.mouse.absolutePosition()
        if not start then fail("GetCursorPos returned nil (secure desktop?)"); return end
        print(string.format("[smoke2]   cursor starts at %d,%d", start.x, start.y))

        local f = hs.screen.primaryScreen():frame()
        local target = { x = f.x + math.floor(f.w / 2), y = f.y + math.floor(f.h / 2) }

        hs.mouse.absolutePosition(target)
        local landed = hs.mouse.absolutePosition()
        hs.mouse.absolutePosition(start)   -- restore before we can fail out

        if not landed then fail("GetCursorPos after move returned nil"); return end
        local dx, dy = math.abs(landed.x - target.x), math.abs(landed.y - target.y)
        if dx > TOL or dy > TOL then
            fail(string.format("cursor moved to %d,%d, wanted ~%d,%d (off by %d,%d)",
                landed.x, landed.y, target.x, target.y, dx, dy)); return
        end

        -- getButtons() is not asserted (we can't know what's held); just exercise it
        -- so a broken GetAsyncKeyState reuse would throw here rather than silently.
        local btns = hs.mouse.getButtons()
        local held = {}
        for k in pairs(btns) do held[#held + 1] = k end
        print("[smoke2]   buttons held right now: " .. (#held > 0 and table.concat(held, ",") or "none"))

        checks.mouse = true
        print(string.format("[smoke2] PASS mouse: set/get round-trip within %dpx, restored.", TOL))
    end
-- END --

-- Check 3: SendInput injection round-trip (needs the runloop) --
    -- The real proof for Thread C. We inject an F13 keyDown/keyUp with SendInput and
    -- catch it on our OWN low-level hook, verifying it comes back flagged injected
    -- and carrying the magic we stamped -- proving both the post side (SendInput
    -- builds a well-formed INPUT) and the read side's self-event tagging. We swallow
    -- both, so the F13 never reaches the focused window.
    --
    -- F13 (VK 0x7C) is the least-harmful key to fire blind: no text, no common
    -- binding, nothing happens even in the unlikely event the swallow misses.
    local VK_F13 = 0x7C
    local MAGIC  = hs.foundation.INJECTED_MAGIC

    -- Watch keyDown/keyUp. Swallow our F13 either way; verdict is set on the keyDown.
    local tap
    tap = hs.eventtap.new({ "keyDown", "keyUp" }, function(ev)
        if ev:getKeyCode() ~= VK_F13 then return false end  -- not ours: pass through

        if ev:getType() == "keyDown" and not checks.inject then
            local injected = ev:getProperty("injected")
            local extra    = ev:getProperty("extra")
            if injected ~= true then
                fail("F13 came back but injected flag was not set"); return true
            end
            if extra ~= MAGIC then
                fail(string.format("F13 injected but magic mismatched: got %s want %s",
                    tostring(extra), tostring(MAGIC))); return true
            end
            checks.inject = true
            print("[smoke2] PASS inject: SendInput round-tripped through our hook, flagged + magic-matched, swallowed.")

            -- All three done -> tidy teardown and let run() return.
            tap:stop()
            hs.shutdown()
        end

        return true  -- swallow both down and up so F13 never leaks
    end)
    tap:start()

    -- Fire the injection just after the loop starts pumping, so the hook is live.
    hs.timer.doAfter(0.5, function()
        hs.eventtap.event.newKeyEvent(nil, VK_F13, true):post()   -- keyDown
        hs.eventtap.event.newKeyEvent(nil, VK_F13, false):post()  -- keyUp
    end)
-- END --

-- Watchdog: never wedge the console if injection never comes back. --
    hs.timer.doAfter(15, function()
        if not checks.inject then
            io.stderr:write("[smoke2] TIMEOUT: F13 never round-tripped in 15s.\n")
            io.stderr:write("        SendInput may not fire, the hook may not see injected events,\n")
            io.stderr:write("        or you are over RDP. See README.\n")
            hs.shutdown()
        end
    end)
-- END --

hs.run()

-- run() returns only after shutdown(). All three slots true => clean pass. --
    if checks.screen and checks.mouse and checks.inject then
        print("[smoke2] PASS: screen, mouse, and injection all exercised on real Win32.")
        os.exit(0)
    else
        io.stderr:write(string.format("[smoke2] INCOMPLETE: screen=%s mouse=%s inject=%s\n",
            tostring(checks.screen), tostring(checks.mouse), tostring(checks.inject)))
        os.exit(1)
    end
-- END --
