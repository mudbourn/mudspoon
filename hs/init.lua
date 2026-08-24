-- mudspoon: the hs namespace --
    -- Frozen wiring. This is the only place modules are assembled into `hs`.
    -- Modules never require each other's public tables through here; they take
    -- what they need from hs.foundation and stay leaf-testable.
    --
    -- Each hs.* module is loaded through optional() so the tree runs with only
    -- the parts that exist today. As work packets A-G land they light up here
    -- with no change to this file.
-- END --

local hs = {}

hs.foundation = require("hs.foundation")

-- Load a module, returning nil (with a note) if it is not built yet.
local function optional(name)
    local ok, mod = pcall(require, name)
    if ok then return mod end
    if tostring(mod):match("module '.-' not found") then return nil end
    error(mod)  -- a real error inside the module: surface it
end

-- Leaf and independent modules (packets A, B, D, E, G) --
    hs.timer    = optional("hs.timer")     -- A
    hs.keycodes = optional("hs.keycodes")  -- D
    hs.screen   = optional("hs.screen")    -- G
    hs.mouse    = optional("hs.mouse")     -- E
-- END --

-- Eventtap: read side is the module, event is its submodule (packets B, C) --
    hs.eventtap = optional("hs.eventtap.tap")  -- B
    local event = optional("hs.eventtap.event")  -- C
    if hs.eventtap and event then
        hs.eventtap.event = event
    end
-- END --

-- Downstream (packet F) --
    hs.hotkey = optional("hs.hotkey")  -- F
-- END --

-- Drive the whole thing.
hs.run      = hs.foundation.run
hs.stop     = hs.foundation.stop
hs.shutdown = hs.foundation.shutdown

return hs
