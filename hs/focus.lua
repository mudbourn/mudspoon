-- hs.focus  (host app-focus hook, leaf) --
    -- Hammerspoon's `hs.focus()` brings the Hammerspoon *application* to the front.
    -- mudspoon has no app shell -- just the native windows its modules create -- so
    -- the equivalent is: raise this process's frontmost real panel window.
    --
    -- mudscript calls `hs.focus()` (no args) ~11 times across its core modules
    -- (guardian, settings, shell, ui), always meaning "bring my panel's host forward".
    -- The panels are hs.webview windows (class "HammerspoonWebView"); hs.canvas
    -- ("HammerspoonCanvas") and hs.alert ("HammerspoonAlert") are transient overlays we do
    -- NOT want to prefer. So we enumerate our own top-level windows in Z-order and pick,
    -- in order of preference: a visible WebView, else a Canvas, else any visible
    -- top-level window of ours -- then SetForegroundWindow + BringWindowToTop it.
    --
    -- This module is unusual: it RETURNS A FUNCTION, not a table (hs.focus is a bare
    -- callable in Hammerspoon). run_mudscript wires it via `hs.focus = require("hs.focus")`.
    --
    -- Depends on hs.foundation for shared TYPES + the loaded user32 only. It cdefs only
    -- its own function prototypes. The three functions foundation/webview may also
    -- declare (GetCurrentProcessId, SetForegroundWindow, BringWindowToTop) are spelled
    -- BYTE-IDENTICALLY here so LuaJIT accepts the redeclaration instead of erroring.
-- END --

local ffi = require("ffi")
local host = require("hs.foundation")
local U = (host.C and host.C.user32) or ffi.load("user32")
local K = (host.C and host.C.kernel32) or ffi.load("kernel32")

ffi.cdef[[
typedef int (__stdcall *MS_WNDENUMPROC)(HWND, LPARAM);
BOOL  EnumWindows(MS_WNDENUMPROC, LPARAM);
DWORD GetWindowThreadProcessId(HWND, DWORD*);
unsigned long GetCurrentProcessId(void);
int   GetClassNameA(HWND, char*, int);
BOOL  IsWindowVisible(HWND);
BOOL  SetForegroundWindow(HWND);
BOOL  BringWindowToTop(HWND);
]]

-- Rank a class name: higher wins. 0 = not one of ours.
local RANK = { HammerspoonWebView = 3, HammerspoonCanvas = 2, HammerspoonAlert = 1 }

local ownPID  = K.GetCurrentProcessId()
local pidBuf  = ffi.new("DWORD[1]")
local nameBuf = ffi.new("char[256]")

-- Best candidate found during one enumeration pass. Enumeration is top-to-bottom in
-- Z-order, so on a rank tie the FIRST (frontmost) window wins -- we only replace on a
-- strictly higher rank.
local best = { hwnd = nil, rank = 0 }

-- One persistent C callback (creating one per call would leak ffi.cast closures).
-- jit.off: a callback body must never be JIT-traced (see hs.foundation host.run) --
-- an error unwinding out of compiled mcode across the FFI boundary panics LuaJIT.
local function enumBody(hwnd, _)
    if U.IsWindowVisible(hwnd) == 0 then return 1 end
    U.GetWindowThreadProcessId(hwnd, pidBuf)
    if pidBuf[0] ~= ownPID then return 1 end
    local n = U.GetClassNameA(hwnd, nameBuf, 256)
    if n > 0 then
        local rank = RANK[ffi.string(nameBuf, n)]
        if rank and rank > best.rank then
            best.hwnd, best.rank = hwnd, rank
        end
    end
    return 1  -- keep enumerating so a later WebView can still outrank an early overlay
end
jit.off(enumBody, true)
local enumProc = ffi.cast("MS_WNDENUMPROC", enumBody)

-- hs.focus(): raise this process's frontmost panel window. Returns true if one was
-- found and raised, false if we own no visible window to focus.
-- jit.off: EnumWindows synchronously invokes enumProc; if this caller were JIT-compiled
-- the callback would be entered from mcode -> "bad callback" panic. mac/ calls this ~11x.
local function focus()
    best.hwnd, best.rank = nil, 0
    U.EnumWindows(enumProc, 0)
    if best.hwnd == nil then return false end
    U.SetForegroundWindow(best.hwnd)
    U.BringWindowToTop(best.hwnd)
    return true
end
jit.off(focus)
return focus
