-- hs.screen  (Thread G, leaf) --
    -- Monitor enumeration and geometry, matching Hammerspoon's `hs.screen`.
    --
    -- Depends on FOUNDATION (`mud.win32`) for shared FFI TYPES only. Per the frozen
    -- cdef-ownership rule: Foundation cdefs the common typedefs (HANDLE, HDC, RECT,
    -- POINT, BOOL, DWORD, LONG, UINT, WORD, BYTE, LPCSTR, LPARAM ...) and loads the
    -- libs once. This module cdefs ONLY its own unique function prototypes and the
    -- MONITORINFOEXA struct, and never redeclares a shared type.
    --
    -- Coordination notes for the other threads:
    --   * GetSystemMetrics is OWNED here (Thread G in the plan). Foundation and other
    --     modules must not cdef it. Anyone needing screen size should call hs.screen.
    --   * Monitor handles are typed as the shared HANDLE (void*), not a new HMONITOR
    --     typedef, so we don't race Foundation over a shared type. ABI-identical.
    --   * mainScreen() does NOT call GetCursorPos -- that primitive belongs to Thread E
    --     (hs.mouse). Until E lands, mainScreen() aliases primaryScreen(). Revisit once
    --     mouse exposes the cursor position through a stable seam.
    --
    -- CONTRACT NOTE: coordinates are Win32 physical pixels, top-left origin, Y down --
    -- which matches Hammerspoon's own screen coordinate space on the primary display.
-- END --

local ffi = require("ffi")

-- Foundation: force shared types + libs to be present. --
    -- Honest hard dependency. If this throws "module 'mud.win32' not found", the
    -- Foundation thread's base has not loaded yet -- load it before hs.screen.
    local win32 = require("mud.win32")

    -- Reuse Foundation's single loaded user32 if it exposes one; otherwise load our
    -- own handle. Loading a lib twice is harmless in LuaJIT (the C declarations are
    -- process-global regardless). This one adapter line is the only place to touch if
    -- Foundation names its exported handles differently.
    local U = (win32 and win32.user32) or ffi.load("user32")
-- END --

-- Own FFI surface (functions + unique struct only; shared types come from Foundation) --
    ffi.cdef[[
typedef struct {
    DWORD cbSize;
    RECT  rcMonitor;
    RECT  rcWork;
    DWORD dwFlags;
    char  szDevice[32];
} MONITORINFOEXA;

typedef BOOL (__stdcall *MONITORENUMPROC)(HANDLE, HDC, RECT*, LPARAM);

BOOL EnumDisplayMonitors(HDC, const RECT*, MONITORENUMPROC, LPARAM);
BOOL GetMonitorInfoA(HANDLE, MONITORINFOEXA*);
int  GetSystemMetrics(int);
]]
-- END --

-- Constants --
    local SM_CXSCREEN          = 0
    local SM_CYSCREEN          = 1
    local MONITORINFOF_PRIMARY = 0x00000001
-- END --

-- Screen object --
    local Screen = {}
    Screen.__index = Screen

    -- Build one screen object from a raw monitor record. --
        -- raw = { id, name, primary, monitor={x,y,w,h}, work={x,y,w,h} }
        local function newScreen(raw)
            return setmetatable(raw, Screen)
        end
    -- END --

    -- :frame() -> usable area, excluding the taskbar (Win32 work area). --
        function Screen:frame()
            local w = self.work
            return { x = w.x, y = w.y, w = w.w, h = w.h }
        end
    -- END --

    -- :fullFrame() -> entire monitor, including the taskbar. --
        function Screen:fullFrame()
            local m = self.monitor
            return { x = m.x, y = m.y, w = m.w, h = m.h }
        end
    -- END --

    -- :name() -> the Win32 device name (e.g. "\\.\DISPLAY1"). --
        function Screen:name()
            return self.deviceName
        end
    -- END --

    -- :id() -> stable-within-session integer id. --
        function Screen:id()
            return self.screenId
        end
    -- END --

    -- :position() -> integer grid position relative to primary (Hammerspoon-ish). --
        -- Approximated from the monitor origin normalised by primary size. Good enough
        -- for left/right/above/below layout queries; not a pixel-exact analog.
        function Screen:position()
            return self.gridX, self.gridY
        end
    -- END --

    -- :currentMode() -> resolution/scale/refresh. --
        -- Scale and refresh are not yet queried (needs EnumDisplaySettings / DPI APIs,
        -- out of this leaf's scope). Report native pixels with scale 1.0 for now.
        function Screen:currentMode()
            return {
                w     = self.monitor.w,
                h     = self.monitor.h,
                scale = 1.0,
                freq  = 0,
            }
        end
    -- END --
-- END --

-- Enumeration --
    -- Collected fresh on each allScreens() call. The callback pushes into this table.
    local collected = {}

    -- MONITORENUMPROC. Kept at module scope so the GC never frees the C callback
    -- while EnumDisplayMonitors still holds it (the standard LuaJIT FFI footgun).
    local enumProc = ffi.cast("MONITORENUMPROC", function(hMonitor, _hdc, _lprc, _lparam)
        local mi = ffi.new("MONITORINFOEXA")
        mi.cbSize = ffi.sizeof("MONITORINFOEXA")

        if U.GetMonitorInfoA(hMonitor, mi) ~= 0 then
            local m = mi.rcMonitor
            local w = mi.rcWork

            collected[#collected + 1] = {
                deviceName = ffi.string(mi.szDevice),
                primary    = (tonumber(mi.dwFlags) % 2) == 1,  -- PRIMARY is bit 0
                monitor    = { x = m.left, y = m.top, w = m.right - m.left, h = m.bottom - m.top },
                work       = { x = w.left, y = w.top, w = w.right - w.left, h = w.bottom - w.top },
            }
        end

        return 1  -- TRUE: keep enumerating
    end)

    -- Fallback single screen from GetSystemMetrics, mirroring the spike's assumption. --
        -- Used only if EnumDisplayMonitors yields nothing (rare: session 0, headless).
        local function fallbackScreen()
            local w = U.GetSystemMetrics(SM_CXSCREEN)
            local h = U.GetSystemMetrics(SM_CYSCREEN)
            return {
                deviceName = "\\\\.\\DISPLAY1",
                primary    = true,
                monitor    = { x = 0, y = 0, w = w, h = h },
                work       = { x = 0, y = 0, w = w, h = h },
            }
        end
    -- END --

    -- Turn raw records into finished Screen objects with ids and grid positions. --
        local function finish(raws)
            -- Primary first so its origin anchors the grid.
            local primary
            for _, r in ipairs(raws) do
                if r.primary then primary = r; break end
            end
            primary = primary or raws[1]

            local pw = math.max(primary.monitor.w, 1)
            local ph = math.max(primary.monitor.h, 1)

            local screens = {}
            for i, r in ipairs(raws) do
                r.screenId = i
                r.gridX = math.floor((r.monitor.x - primary.monitor.x) / pw + 0.5)
                r.gridY = math.floor((r.monitor.y - primary.monitor.y) / ph + 0.5)
                screens[i] = newScreen(r)
            end
            return screens
        end
    -- END --
-- END --

-- Public API --
    local screen = {}

    -- hs.screen.allScreens() -> array of screen objects. --
        function screen.allScreens()
            for i = #collected, 1, -1 do collected[i] = nil end  -- clear in place

            U.EnumDisplayMonitors(nil, nil, enumProc, 0)

            local raws = collected
            if #raws == 0 then raws = { fallbackScreen() } end

            return finish(raws)
        end
    -- END --

    -- hs.screen.primaryScreen() -> the primary display. --
        function screen.primaryScreen()
            local all = screen.allScreens()
            for _, s in ipairs(all) do
                if s.primary then return s end
            end
            return all[1]
        end
    -- END --

    -- hs.screen.mainScreen() -> display with keyboard focus. --
        -- Approximation: aliases primaryScreen() until Thread E (hs.mouse) exposes the
        -- cursor position. Do not add a GetCursorPos cdef here -- that primitive is E's.
        function screen.mainScreen()
            return screen.primaryScreen()
        end
    -- END --
-- END --

return screen
