-- hs.canvas  (minimal: real constants + no-op drawing objects) --
    -- Hammerspoon's hs.canvas is a full vector-drawing surface. mudscript uses it for
    -- the loading "curtain" overlay. A real Win32/GDI+ implementation is a large future
    -- packet; until then this provides what the config needs to LOAD and RUN without a
    -- curtain: the two constant tables it reads for numeric window levels/behaviors, and
    -- a canvas object whose every method no-ops (so :appendElements():show()... chains
    -- do nothing rather than crash). The overlay is simply invisible for now.
    --
    -- Why not the bootstrap black-hole: mac/ evaluates `hs.canvas.windowLevels.screenSaver
    -- + 1` at load time; a black-hole makes that a table (truthy, non-arithmetic) and boot
    -- dies. These must be real NUMBERS. Remove "canvas" from run_mudscript's STUB_MODULES
    -- so this file wins over the preload stub.
-- END --

local canvas = {}

-- windowLevels: numeric NSWindow-style levels mudscript indexes (screenSaver etc.) --
    -- Values mirror Hammerspoon/NSWindowLevel ordering; only relative magnitude matters.
    canvas.windowLevels = {
        normal            = 0,
        floating          = 3,
        tornOffMenu       = 3,
        modalPanel        = 8,
        utility           = 19,
        dock              = 20,
        mainMenu          = 24,
        status            = 25,
        popUpMenu         = 101,
        overlay           = 102,
        help              = 200,
        dragging          = 500,
        screenSaver       = 1000,
        assistiveTechHigh = 1500,
        cursor            = 2001,
    }
-- END --

-- windowBehaviors: NSWindowCollectionBehavior bit flags mudscript OR-combines --
    canvas.windowBehaviors = {
        default              = 0,
        canJoinAllSpaces     = 1,
        moveToActiveSpace    = 2,
        managed              = 4,
        transient            = 8,
        stationary           = 16,
        participatesInCycle  = 32,
        ignoresCycle         = 64,
        fullScreenPrimary    = 128,
        fullScreenAuxiliary  = 256,
        fullScreenNone       = 512,
    }
-- END --

-- Canvas object: every method a chainable no-op (invisible until a real impl lands) --
    -- Same shape as run_mudscript's black-hole: indexing yields the object (so both
    -- namespace and method access resolve) and it is callable, so obj:show():alpha(1)
    -- and obj[1] = {...} both no-op safely.
    local function stubCanvas()
        local o = {}
        setmetatable(o, {
            __index    = function() return o end,
            __call     = function() return o end,
            __newindex = function() end,        -- swallow element assignment (c[1] = {...})
            __tostring = function() return "<hs.canvas stub>" end,
        })
        return o
    end

    function canvas.new() return stubCanvas() end
    function canvas.elementCount() return 0 end
-- END --

return canvas
