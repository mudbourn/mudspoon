-- hs.axuielement  (leaf; accessibility elements via Windows UI Automation) --
    -- Hammerspoon's hs.axuielement over the top of Windows UIA. It is a THIN facade:
    -- all COM, the element object, and the element attribute mapping live in the shared
    -- hs.uia substrate (see hs/uia.lua) so this module and hs.uielement cannot diverge
    -- on how a UIA element is created, released, or read. This module contributes only
    -- the axuielement-shaped entry points.
    --
    -- Depends on hs.uia (shared UIA bootstrap) which itself depends on hs.foundation
    -- for the shared Win32 typedefs and the one runloop/timer thread. No FFI is cdef'd
    -- here -- the frozen cdef-ownership rule keeps every COM/Win32 declaration in uia.
    --
    -- SURFACE implemented (only what the consumer, mudscript, actually calls, plus the
    -- element methods those elements minimally need):
    --   * hs.axuielement.systemWideElement()          -> the desktop root element
    --   * hs.axuielement.systemElementAtPosition(x,y)  -> element under a screen point
    -- Returned elements carry :attributeValue / :role / :title / :isValid / :pid and
    -- compare by identity (== uses UIA CompareElements). See hs.uia for the object.
    --
    -- COORDINATES: systemElementAtPosition takes logical screen coordinates (the same
    -- space hs.screen and hs.mouse use); uia scales to physical pixels for UIA.
    --
    -- UNVERIFIED: cannot be exercised here (needs a real Windows desktop session). See
    -- the module summary for what remains to confirm on hardware.
-- END --

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
