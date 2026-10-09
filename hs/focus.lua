-- hs.focus raises this process's frontmost panel window

local ffi = require("ffi")
local host = require("hs.foundation")
local U = (host.C and host.C.user32) or ffi.load("user32")

ffi.cdef[[
typedef int (__stdcall *MS_WNDENUMPROC)(HWND, LPARAM);
BOOL  EnumWindows(MS_WNDENUMPROC, LPARAM);
DWORD GetWindowThreadProcessId(HWND, DWORD*);
int   GetClassNameA(HWND, char*, int);
BOOL  IsWindowVisible(HWND);
BOOL  SetForegroundWindow(HWND);
BOOL  BringWindowToTop(HWND);
]]

-- Rank a class name: higher wins. 0 = not one of ours.
local RANK = { HammerspoonWebView = 3, HammerspoonCanvas = 2, HammerspoonAlert = 1 }

local ownPID  = host.pid
local pidBuf  = ffi.new("DWORD[1]")
local nameBuf = ffi.new("char[256]")

-- Best candidate found during one enumeration pass. Enumeration is top-to-bottom in
-- Z-order, so on a rank tie the FIRST (frontmost) window wins -- we only replace on a
-- strictly higher rank.
local best = { hwnd = nil, rank = 0 }

-- One persistent C callback (creating one per call would leak ffi.cast closures).
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
local enumProc = ffi.cast("MS_WNDENUMPROC", enumBody)

local function focus()
    best.hwnd, best.rank = nil, 0
    U.EnumWindows(enumProc, 0)
    if best.hwnd == nil then return false end
    U.SetForegroundWindow(best.hwnd)
    U.BringWindowToTop(best.hwnd)
    return true
end
return focus
