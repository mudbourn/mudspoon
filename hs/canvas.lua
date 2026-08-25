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

-- Canvas object: minimal STATEFUL stub (invisible, but geometry reads real numbers) --
    -- A pure black-hole broke callers that read geometry back: c:frame().y must be a
    -- NUMBER, not another stub, or their animation math (mudscript's ms_alert) does
    -- `toY - fromY` on a table and loops forever erroring. So track frame + alpha and
    -- return real numbers from the getters; every other method is a chainable no-op.
    local function stubCanvas(rect)
        rect = rect or {}
        local self = {
            _frame = { x = rect.x or 0, y = rect.y or 0, w = rect.w or 0, h = rect.h or 0 },
            _alpha = 1,
        }

        -- :frame([rect]) -> rect (copy) as getter, or set + return self.
        function self:frame(r)
            local f = self._frame
            if r == nil then return { x = f.x, y = f.y, w = f.w, h = f.h } end
            self._frame = { x = r.x or f.x, y = r.y or f.y, w = r.w or f.w, h = r.h or f.h }
            return self
        end
        function self:topLeft(p)
            local f = self._frame
            if p == nil then return { x = f.x, y = f.y } end
            f.x = p.x or f.x; f.y = p.y or f.y
            return self
        end
        function self:size(s)
            local f = self._frame
            if s == nil then return { w = f.w, h = f.h } end
            f.w = s.w or f.w; f.h = s.h or f.h
            return self
        end
        function self:alpha(a)
            if a == nil then return self._alpha end
            self._alpha = a
            return self
        end

        -- Everything else (show/hide/delete/appendElements/level/...) is a chainable
        -- no-op; element assignment c[1] = {...} is swallowed. Real methods above are
        -- rawkeys, so __index only fires for the unimplemented rest.
        return setmetatable(self, {
            __index    = function() return function() return self end end,
            __newindex = function() end,
        })
    end

    function canvas.new(rect) return stubCanvas(rect) end
    function canvas.elementCount() return 0 end
-- END --

return canvas
