-- hs.focus  (make mudspoon the foreground app) --
    -- Hammerspoon's hs.focus() is a bare top-level FUNCTION (MJLua.m: core_focus ->
    -- [NSApplication activateIgnoringOtherApps:YES]) that brings Hammerspoon itself
    -- to the foreground. mac/ calls it 11x, always right before it drives keystrokes
    -- into its own shell window so the OS delivers them to us.
    --
    -- The Windows equivalent: find a top-level window owned by OUR process and
    -- SetForegroundWindow it. We reuse hs.window's enumerator/pid seams rather than
    -- re-cdef'ing EnumWindows (foundation/window own those types).
    --
    -- Windows' foreground-lock rules (SetForegroundWindow may be refused unless the
    -- caller already owns the foreground or input is idle) apply here exactly as they
    -- do for hs.window:focus(); the BringWindowToTop + restore-if-minimised dance is
    -- the same best-effort we can make from user space. RIG-UNVERIFIED like the rest
    -- of the Win32 surface, but built only from types already proven in hs.window.
-- END --

local ffi    = require("ffi")
local host   = require("hs.foundation")
local window = require("hs.window")

-- GetCurrentProcessId is the one function this module needs that neither foundation
-- nor window declares. Per the cdef-ownership rule we may cdef our own unique funcs.
    ffi.cdef([[ unsigned long GetCurrentProcessId(void); ]])
    local K = host.C.kernel32
-- END --

-- Pick the best window to raise: prefer a visible, titled top-level window owned by
-- our PID; fall back to the first visible one; last resort the first one at all. This
-- mirrors how a Cocoa app activation lands on the app's key/main window.
    local function ownForegroundTarget()
        local mypid   = tonumber(K.GetCurrentProcessId())
        local hwnds   = window._enumTopLevel()
        local visible, any
        for _, h in ipairs(hwnds) do
            if window._pidOf(h) == mypid then
                any = any or h
                if window._isVisible(h) then
                    visible = visible or h
                    -- A titled visible window is the shell proper; take it eagerly.
                    if window._titleOf(h) ~= "" then return h end
                end
            end
        end
        return visible or any
    end
-- END --

-- hs.focus() -> None. Best-effort bring-our-app-forward. Never raises (a refused
-- SetForegroundWindow is a normal outcome under foreground lock), so the callers'
-- "focus then type" sequence proceeds regardless.
    return function()
        local ok, hwnd = pcall(ownForegroundTarget)
        if not ok or hwnd == nil then return end
        -- Route through hs.window:focus() so the restore/BringWindowToTop/
        -- SetForegroundWindow policy stays in ONE place.
        local w = window._newWindow(hwnd)
        pcall(function() w:focus() end)
    end
-- END --
