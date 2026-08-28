-- hs.window.filter  (WinEvent-backed window-event subscriptions) --
    -- A slice of Hammerspoon's hs.window.filter: enough for mac/'s macro window
    -- move/resize recorder, which does wf = hs.window.filter.new(nil); wf:subscribe(
    -- hs.window.filter.windowMoved, cb) and reads wf:getWindows().
    --
    -- Backed by foundation's WinEvent source (host.onWinEvent). We do NOT implement
    -- hs.window.filter's rich scoping/predicate DSL (app allow/deny lists, visibility
    -- rules, region filters) -- new(nil) means "every top-level window" and that is
    -- the only scope the consumer uses. The event stream and the window-object shape
    -- (:application():name(), :id(), :frame()) are what mac/ actually touches.
    --
    -- Depends on FOUNDATION for the WinEvent source + event constants, and on
    -- hs.window for the window object + top-level enumeration. hs.window is required
    -- LAZILY inside methods: window.lua eager-requires this module at its end (so
    -- hs.window.filter resolves), and a top-level require here would re-enter a
    -- half-loaded hs.window. By the time these methods run, hs.window is fully loaded.
-- END --

local host = require("hs.foundation")
local U    = host.C.user32

local filter = {}

-- Event constants (strings, matching Hammerspoon's names). windowMoved is the
-- load-bearing one; windowsChanged is a catch-all that fires for ANY tracked change
-- (create/destroy/show/hide/move), which is how mac/ uses it as a coarse "resync".
filter.windowCreated   = "windowCreated"
filter.windowDestroyed = "windowDestroyed"
filter.windowMoved     = "windowMoved"
filter.windowVisible   = "windowVisible"
filter.windowNotVisible = "windowNotVisible"
filter.windowsChanged  = "windowsChanged"

-- Lazy hs.window resolver (see header: avoids a load-time cycle).
local function windowMod()
    local ok, w = pcall(require, "hs.window")
    if ok and type(w) == "table" then return w end
    return nil
end

local Filter = {}
Filter.__index = Filter

-- hs.window.filter.new([arg]) -> filter. arg is ignored (only the "all windows"
-- scope, spelled new(nil) by mac/, is supported). Returns a filter with no
-- subscriptions until :subscribe is called.
function filter.new(_arg)
    return setmetatable({
        _subs  = {},   -- list of { events = <set>, cb = <fn> }
        _unsub = nil,  -- host.onWinEvent unsubscribe handle while any sub is active
    }, Filter)
end

-- :getWindows() -> current top-level windows (the "all windows" scope snapshot).
function Filter:getWindows()
    local w = windowMod()
    if not w or type(w.allWindows) ~= "function" then return {} end
    return w.allWindows()
end

-- Normalise the events arg (a single constant or a list) into a lookup set.
local function toEventSet(events)
    local set = {}
    if type(events) == "table" then
        for _, e in ipairs(events) do set[e] = true end
    elseif events ~= nil then
        set[events] = true
    end
    return set
end

-- Map a raw WinEvent to the high-level filter events it should raise. Returns a
-- list because one OS event can map to both a specific event and windowsChanged.
local W = host.winEvents
local function classify(event)
    if event == W.locationChange then
        return { filter.windowMoved, filter.windowsChanged }
    elseif event == W.objectCreate then
        return { filter.windowCreated, filter.windowsChanged }
    elseif event == W.objectDestroy then
        return { filter.windowDestroyed, filter.windowsChanged }
    elseif event == W.objectShow then
        return { filter.windowVisible, filter.windowsChanged }
    elseif event == W.objectHide then
        return { filter.windowNotVisible, filter.windowsChanged }
    end
    return nil
end

-- Install the shared WinEvent subscription once, the first time this filter has a
-- subscriber. The handler builds a window object and fans out to matching subs.
local function ensureSource(self)
    if self._unsub then return end
    self._unsub = host.onWinEvent(function(event, hwnd, idObject, idChild)
        -- Top-level window objects only (skip child controls, caret, cursor).
        if idObject ~= W.OBJID_WINDOW or idChild ~= W.CHILDID_SELF then return end
        if hwnd == nil then return end

        local kinds = classify(event)
        if not kinds then return end

        local w = windowMod()
        if not w or type(w._newWindow) ~= "function" then return end

        -- Gate "positive" events (moved/created/shown) to the same universe getWindows
        -- returns -- visible, titled top-level windows -- so the chatty LOCATIONCHANGE
        -- stream doesn't deliver zero-size / untitled helper windows (IME hosts, DWM
        -- surfaces) that pass the object/child check. Destroy/hide are not gated: the
        -- window is gone or hidden by definition, so a visibility test is meaningless.
        if event == W.locationChange or event == W.objectCreate or event == W.objectShow then
            local vis = type(w._isVisible) == "function" and w._isVisible(hwnd)
            local titled = type(w._titleOf) == "function" and w._titleOf(hwnd) ~= ""
            if not (vis and titled) then return end
        end

        local win = w._newWindow(hwnd)
        if not win then return end

        -- appName is best-effort: on a destroy the owning process may already be gone.
        local appName
        do
            local ok, appObj = pcall(function() return win:application() end)
            if ok and appObj then
                local okn, n = pcall(function() return appObj:name() end)
                if okn then appName = n end
            end
        end

        for _, sub in ipairs(self._subs) do
            for _, kind in ipairs(kinds) do
                if sub.events[kind] then
                    local okcb, err = pcall(sub.cb, win, appName, kind)
                    if not okcb then
                        io.stderr:write("hs.window.filter callback error: " .. tostring(err) .. "\n")
                    end
                    break  -- one event fires a given callback at most once per OS event
                end
            end
        end
    end)
end

-- :subscribe(events, cb) -> self. events is a filter.* constant or a list of them;
-- cb is called cb(window, appName, event). May be called repeatedly to add more.
function Filter:subscribe(events, cb)
    if type(cb) ~= "function" then
        error("hs.window.filter:subscribe expects (events, callback)", 2)
    end
    self._subs[#self._subs + 1] = { events = toEventSet(events), cb = cb }
    ensureSource(self)
    return self
end

-- :unsubscribeAll() -> self. Drops every subscription and releases the WinEvent
-- source (the OS hook goes away when this was foundation's last WinEvent subscriber).
function Filter:unsubscribeAll()
    self._subs = {}
    if self._unsub then self._unsub(); self._unsub = nil end
    return self
end

return filter
