-- hs.hotkey  (Thread F) --
    -- Hammerspoon's hotkey API, matched over Thread B's eventtap and Thread D's
    -- keycodes. A hotkey is a (modifier-set, key) chord with pressed/released/
    -- repeat callbacks; a match swallows the key so the focused app never sees it.
    --
    -- Depends on B (hs.eventtap read) and D (hs.keycodes). No hook or loop of its
    -- own: one shared eventtap watches keyDown/keyUp and dispatches to the
    -- registry, started lazily on the first enabled hotkey and stopped when none
    -- remain.
    --
    -- Limitation from D's map: "fn" has no Win32 virtual-key code, so a chord that
    -- requires fn can never match. Matches the keycodes contract; do not rely on it.
-- END --

local eventtap = require("hs.eventtap.tap")
local keycodes = require("hs.keycodes")

local hotkey = {}

-- Modifier normalisation --
    -- Every accepted spelling -> one of the four canonical flags the event object
    -- reports (cmd aliases the Win key, per contract 1 / hs.keycodes).
    local MOD_ALIAS = {
        cmd = "cmd", command = "cmd", ["⌘"] = "cmd", win = "cmd", super = "cmd", meta = "cmd",
        alt = "alt", option = "alt", opt = "alt", ["⌥"] = "alt",
        ctrl = "ctrl", control = "ctrl", ["⌃"] = "ctrl",
        shift = "shift", ["⇧"] = "shift",
    }

    local CANON = { "cmd", "alt", "ctrl", "shift" }

    -- Accepts a table of mod strings, or a single mod string. Returns a set.
    local function normalizeMods(mods)
        local set = {}
        if type(mods) == "string" then mods = { mods } end
        for _, m in ipairs(mods or {}) do
            local canon = MOD_ALIAS[tostring(m):lower()] or MOD_ALIAS[m]
            if canon then set[canon] = true end
        end
        return set
    end

    -- Exact match: every required modifier held, and no extra modifier held.
    local function flagsMatch(required, flags)
        for _, m in ipairs(CANON) do
            if (required[m] == true) ~= (flags[m] == true) then return false end
        end
        return true
    end
-- END --

-- Key normalisation --
    -- A key name (via keycodes) or a raw virtual-key number.
    local function resolveKey(key)
        if type(key) == "number" then return key end
        local code = keycodes.map[key]
        if not code then error("hs.hotkey: unknown key '" .. tostring(key) .. "'", 3) end
        return code
    end
-- END --

-- Shared tap + registry --
    local enabled = {}  -- array of enabled hotkeys
    local tap           -- the one shared eventtap, or nil when nothing is enabled

    -- Fire a callback without letting an error escape into dispatch.
    local function safe(fn)
        if not fn then return end
        local ok, err = pcall(fn)
        if not ok then io.stderr:write("hammerspoon hotkey callback error: " .. tostring(err) .. "\n") end
    end

    local function onEvent(ev)
        local code, etype, flags = ev:getKeyCode(), ev:getType(), ev:getFlags()
        local swallow = false

        for _, hk in ipairs(enabled) do
            if etype == "keyDown" then
                if hk.keyCode == code and flagsMatch(hk.mods, flags) then
                    if hk._down then
                        safe(hk.repeatfn)
                    else
                        hk._down = true
                        safe(hk.pressedfn)
                    end
                    swallow = true
                end
            else  -- keyUp: release by keycode regardless of current mods, so a
                  -- modifier released before the key can't strand a hotkey "down".
                if hk.keyCode == code and hk._down then
                    hk._down = false
                    safe(hk.releasedfn)
                    swallow = true
                end
            end
        end

        return swallow
    end

    local function ensureTap()
        if tap then return end
        tap = eventtap.new({ "keyDown", "keyUp" }, onEvent)
        tap:start()
    end

    local function register(hk)
        if hk.enabled then return end
        hk.enabled = true
        enabled[#enabled + 1] = hk
        ensureTap()
    end

    local function unregister(hk)
        if not hk.enabled then return end
        hk.enabled = false
        hk._down   = false
        for i = #enabled, 1, -1 do
            if enabled[i] == hk then table.remove(enabled, i) break end
        end
        if #enabled == 0 and tap then tap:stop(); tap = nil end
    end
-- END --

-- Hotkey object --
    local Hotkey = {}
    Hotkey.__index = Hotkey

    function Hotkey:enable()  register(self);   return self end
    function Hotkey:disable() unregister(self); return self end

    -- Hammerspoon returns nil from delete; the object is dead afterward.
    function Hotkey:delete()
        unregister(self)
        return nil
    end
-- END --

-- Constructors --
    -- Signature matches Hammerspoon:
    --   new(mods, key, [message,] pressedfn, [releasedfn, [repeatfn]])
    -- message is accepted for compatibility (no alert layer here) and ignored.
    local function parse(a, b, c, d)
        if type(a) == "string" then
            return a, b, c, d          -- a is the message; callbacks shift right
        end
        return nil, a, b, c            -- no message; a is pressedfn
    end

    function hotkey.new(mods, key, a, b, c, d)
        local _message, pressedfn, releasedfn, repeatfn = parse(a, b, c, d)
        return setmetatable({
            mods       = normalizeMods(mods),
            keyCode    = resolveKey(key),
            pressedfn  = pressedfn,
            releasedfn = releasedfn,
            repeatfn   = repeatfn,
            enabled    = false,
            _down      = false,
        }, Hotkey)
    end

    -- bind = new + enable, the common path.
    function hotkey.bind(mods, key, a, b, c, d)
        return hotkey.new(mods, key, a, b, c, d):enable()
    end
-- END --

-- Bulk controls --
    -- Disable every enabled hotkey (Hammerspoon parity). Objects can be re-enabled.
    function hotkey.disableAll()
        for i = #enabled, 1, -1 do unregister(enabled[i]) end
    end
-- END --

return hotkey
