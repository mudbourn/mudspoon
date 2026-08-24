-- hs.mouse  (Thread E) --
    -- Cursor position and button state, matching Hammerspoon's `hs.mouse`.
    --
    -- Depends on FOUNDATION (`hs.foundation`) for shared types + the loaded user32,
    -- and SOFTLY on Thread G (`hs.screen`) for getCurrentScreen(). The G dependency
    -- is a soft require: if screen is not built yet, getCurrentScreen() returns nil
    -- and everything else still works, so this module stays leaf-testable.
    --
    -- Owns the cdefs for GetCursorPos / SetCursorPos only. Button state reuses
    -- foundation's already-declared GetAsyncKeyState (re-cdef would collide), called
    -- through the same loaded user32 handle.
    --
    -- COORDINATES: Win32 virtual-desktop pixels, top-left origin, Y down. Multi-
    -- monitor setups can yield negative coordinates for displays left of / above the
    -- primary. This is the same space hs.screen frames and hook events report in, so
    -- points pass between the three modules unchanged.
-- END --

local ffi = require("ffi")
local bit = require("bit")

local host = require("hs.foundation")
local U    = (host.C and host.C.user32) or ffi.load("user32")

-- Soft dependency on hs.screen (Thread G). --
    -- pcall so mouse loads and tests standalone before/without screen. A real error
    -- inside screen still surfaces; only "module not found" is swallowed.
    local screen
    do
        local ok, mod = pcall(require, "hs.screen")
        if ok then
            screen = mod
        elseif not tostring(mod):match("module '.-' not found") then
            error(mod)
        end
    end
-- END --

-- Own FFI surface (functions only; POINT comes from foundation) --
    ffi.cdef[[
BOOL GetCursorPos(POINT*);
BOOL SetCursorPos(int, int);
]]
-- END --

-- Constants --
    local VK_LBUTTON = 0x01
    local VK_RBUTTON = 0x02
    local VK_MBUTTON = 0x04
    local HIGH_BIT   = 0x8000

    -- Reused scratch buffer for GetCursorPos; single-threaded runloop, so safe.
    local ptBuf = ffi.new("POINT")
-- END --

-- Pure helpers (leaf-testable) --
    -- Is point (px,py) inside a screen's fullFrame rect? Half-open on the far edges
    -- so a point on the shared border between two monitors lands in exactly one.
    local function inRect(px, py, r)
        return px >= r.x and px < r.x + r.w
           and py >= r.y and py < r.y + r.h
    end

    -- Accept both {x=,y=} and positional {px, py} point tables (Hammerspoon-ish).
    local function readPoint(p)
        if p.x ~= nil then return p.x, p.y end
        return p[1], p[2]
    end
-- END --

local mouse = {}

-- Position: get --
    -- hs.mouse.absolutePosition() with no argument -> current cursor as {x=,y=}.
    -- Returns nil if GetCursorPos fails (e.g. secure desktop).
    local function getPos()
        if U.GetCursorPos(ptBuf) == 0 then return nil end
        return { x = tonumber(ptBuf.x), y = tonumber(ptBuf.y) }
    end
-- END --

-- Position: set --
    local function setPos(p)
        local x, y = readPoint(p)
        U.SetCursorPos(x, y)
    end
-- END --

-- Public: absolute position (Hammerspoon's overloaded getter/setter) --
    -- hs.mouse.absolutePosition()      -> point
    -- hs.mouse.absolutePosition(point) -> moves the cursor
    function mouse.absolutePosition(p)
        if p == nil then return getPos() end
        setPos(p)
    end

    -- Legacy explicit names (older scripts / clarity).
    function mouse.getAbsolutePosition() return getPos() end
    function mouse.setAbsolutePosition(p) setPos(p) end
-- END --

-- Public: current screen (soft G dependency) --
    -- hs.mouse.getCurrentScreen() -> the screen whose fullFrame contains the cursor,
    -- or the primary as a fallback. Returns nil only if hs.screen is not built yet
    -- or the cursor position is unavailable.
    function mouse.getCurrentScreen()
        if not screen then return nil end
        local pos = getPos()
        if not pos then return nil end

        for _, s in ipairs(screen.allScreens()) do
            if inRect(pos.x, pos.y, s:fullFrame()) then return s end
        end
        return screen.primaryScreen()
    end
-- END --

-- Public: position relative to the current screen's origin --
    -- hs.mouse.getRelativePosition() -> {x=,y=} measured from the top-left of the
    -- screen under the cursor. Falls back to absolute if screen is unavailable.
    function mouse.getRelativePosition()
        local pos = getPos()
        if not pos then return nil end

        local s = mouse.getCurrentScreen()
        if not s then return pos end

        local f = s:fullFrame()
        return { x = pos.x - f.x, y = pos.y - f.y }
    end
-- END --

-- Public: button state --
    -- hs.mouse.getButtons() -> set-table of currently held buttons, truthy keys only
    -- (left, right, middle), mirroring the modifier-flag style foundation uses.
    -- Reflects logical buttons, so a swapped (left-handed) mouse reports as the user
    -- sees it. Reuses foundation's GetAsyncKeyState -- not re-declared here.
    local function held(vk)
        return bit.band(U.GetAsyncKeyState(vk), HIGH_BIT) ~= 0
    end

    function mouse.getButtons()
        local b = {}
        if held(VK_LBUTTON) then b.left   = true end
        if held(VK_RBUTTON) then b.right  = true end
        if held(VK_MBUTTON) then b.middle = true end
        return b
    end
-- END --

-- Test seam: expose pure helpers so they can be unit-tested without FFI/Win32. --
    mouse._inRect    = inRect
    mouse._readPoint = readPoint
-- END --

return mouse
