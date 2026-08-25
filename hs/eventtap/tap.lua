-- hs.eventtap  (Thread B, read side) --
    -- Hammerspoon's eventtap over Foundation's host dispatch. A tap watches a set
    -- of event types; its callback receives an event object and may swallow the
    -- event or emit replacements.
    --
    -- Depends on Foundation (host.onKey / host.onMouse) and contract 1 (the event
    -- object). It installs no hook itself -- Foundation owns the one keyboard and
    -- one mouse low-level hook and fans out to whoever subscribed.
    --
    -- Callback contract, matching Hammerspoon:
    --   fn(event) -> deleteEvent [, { event, event, ... }]
    --     * deleteEvent truthy  -> the OS never sees the event (swallowed)
    --     * second return       -> event objects to :post() in its place
    --       (posting needs hs.eventtap.event / Thread C; if that is not loaded and
    --        a callback returns events, :post() will raise -- by contract 1.)
-- END --

local host = require("hs.foundation")

local eventtap = {}

-- Which event types route to the keyboard hook; everything else is a mouse type.
-- flagsChanged is emitted by the key hook (modifier transitions), so it must route
-- there too — otherwise a tap on it subscribes to the mouse hook and never fires.
local KEY_TYPES = { keyDown = true, keyUp = true, flagsChanged = true }

-- Eventtap object --
    local Tap = {}
    Tap.__index = Tap

    -- One handler shared by both host subscriptions. Filters by this tap's type
    -- set, runs the user callback, posts any returned events, and reports whether
    -- to swallow. Errors are contained so one bad callback can't kill the loop.
    local function makeHandler(self)
        return function(ev)
            if not self._set[ev:getType()] then return false end

            local ok, del, posts = pcall(self._fn, ev)
            if not ok then
                io.stderr:write("mudspoon eventtap callback error: " .. tostring(del) .. "\n")
                return false
            end

            if type(posts) == "table" then
                for _, e in ipairs(posts) do e:post() end
            end
            return del == true
        end
    end

    function Tap:start()
        if self._enabled then return self end
        local h = makeHandler(self)
        if self._wantsKey   then self._unsubs[#self._unsubs + 1] = host.onKey(h)   end
        if self._wantsMouse then self._unsubs[#self._unsubs + 1] = host.onMouse(h) end
        self._enabled = true
        return self
    end

    function Tap:stop()
        for _, unsub in ipairs(self._unsubs) do unsub() end
        self._unsubs = {}
        self._enabled = false
        return self
    end

    function Tap:isEnabled()
        return self._enabled == true
    end
-- END --

-- Constructor --
    -- hs.eventtap.new(types, fn): types is an array of event-type strings (the
    -- contract-1 names, which are exactly the values in hs.eventtap.event.types).
    function eventtap.new(types, fn)
        local set, wantsKey, wantsMouse = {}, false, false
        for _, t in ipairs(types) do
            set[t] = true
            if KEY_TYPES[t] then wantsKey = true else wantsMouse = true end
        end
        return setmetatable({
            _set        = set,
            _fn         = fn,
            _wantsKey   = wantsKey,
            _wantsMouse = wantsMouse,
            _enabled    = false,
            _unsubs     = {},
        }, Tap)
    end
-- END --

return eventtap
