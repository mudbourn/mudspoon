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
    applicationActivated = "AXApplicationActivated",
    applicationDeactivated = "AXApplicationDeactivated",
    applicationHidden = "AXApplicationHidden",
    applicationShown = "AXApplicationShown",
    mainWindowChanged = "AXMainWindowChanged",
    focusedWindowChanged = "AXFocusedWindowChanged",
    focusedElementChanged = "AXFocusedUIElementChanged",
    windowCreated = "AXWindowCreated",
    windowMoved = "AXWindowMoved",
    windowResized = "AXWindowResized",
    windowMinimized = "AXWindowMiniaturized",
    windowUnminimized = "AXWindowDeminiaturized",
    elementDestroyed = "AXUIElementDestroyed",
    titleChanged = "AXTitleChanged",
    new = function(element, fn, userdata)
        if type(element) ~= "table" or type(element.newWatcher) ~= "function" then
            error("hs.uielement.watcher.new expects a uielement as the first argument", 2)
        end
        return element:newWatcher(fn, userdata)
    end,
}

return uielement
