-- hs.uielement  (leaf; focused UI element + focus watcher via Windows UI Automation) --
    -- Hammerspoon's hs.uielement over Windows UIA. Like hs.axuielement it is a THIN
    -- facade over the shared hs.uia substrate (hs/uia.lua): the element object and the
    -- watcher both live there, so both public modules hand back the exact same element
    -- shape and share one CUIAutomation instance. This module contributes the
    -- uielement-shaped entry points.
    --
    -- Depends on hs.uia (shared UIA bootstrap) -> hs.foundation. No FFI is cdef'd here.
    --
    -- SURFACE implemented (only what mudscript calls):
    --   * hs.uielement.focusedElement()   -> the element with keyboard focus
    --   * hs.uielement.watcher            -> the watcher factory table; in practice a
    --     watcher is created as element:newWatcher(fn[, userdata]) then :start{events}
    --     / :stop, exactly as in Hammerspoon. The watcher is POLL-BASED on the
    --     foundation timer scheduler (no private thread / no COM event sink); see the
    --     WATCHER note in hs/uia.lua for the rationale and trade-offs.
    --
    -- UNVERIFIED: needs a real Windows desktop session to exercise (see summary).
-- END --

local uia = require("hs.uia")

local uielement = {}

-- hs.uielement.focusedElement() -> the element that currently has keyboard focus, or
-- nil if UIA is unavailable / nothing is focused.
function uielement.focusedElement()
    return uia.getFocused()
end

-- hs.uielement.watcher -- the watcher factory. Hammerspoon exposes watchers as
-- element:newWatcher(...); :newWatcher lives on the shared element object (hs.uia), so
-- both hs.uielement and hs.axuielement elements can spawn one. This table is the public
-- handle Hammerspoon code references as hs.uielement.watcher; .new(element, fn, ud)
-- mirrors the method form for callers that prefer the free-function style.
uielement.watcher = {
    new = function(element, fn, userdata)
        if type(element) ~= "table" or type(element.newWatcher) ~= "function" then
            error("hs.uielement.watcher.new expects a uielement as the first argument", 2)
        end
        return element:newWatcher(fn, userdata)
    end,
}

return uielement
