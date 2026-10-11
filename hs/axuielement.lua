local uia = require("hs.uia")

local axuielement = {}

-- hs.axuielement.systemWideElement() -> the root (desktop) element, or nil if UIA is
-- unavailable. Hammerspoon returns a systemwide element; UIA's root element is the
-- closest analogue and the anchor for walking the tree.
function axuielement.systemWideElement()
    return uia.getRoot()
end

-- hs.axuielement.systemElementAtPosition(x, y) -> the element at a screen point, or
-- nil. Accepts either (x, y) or a single {x=,y=}/point table, matching Hammerspoon's
-- tolerant point argument.
function axuielement.systemElementAtPosition(x, y)
    if type(x) == "table" then x, y = x.x, x.y end
    return uia.fromPoint(x, y)
end

return axuielement
