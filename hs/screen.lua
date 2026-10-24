-- hs.screen  (Thread G, leaf) --
    -- Monitor enumeration and geometry, matching Hammerspoon's `hs.screen`.
    --
    -- Depends on FOUNDATION (`hs.foundation`) for shared FFI TYPES only. Per the
    -- frozen cdef-ownership rule: foundation cdefs the common typedefs (HANDLE, HDC,
    -- RECT, POINT, BOOL, DWORD, LONG, UINT, WORD, BYTE, LPCSTR, LPARAM ...) and loads
    -- the libs once (exposed as host.C.user32/.kernel32/.gdi32). This module cdefs
    -- ONLY its own unique function prototypes and the MONITORINFOEXA struct, and
    -- never redeclares a shared type.
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

-- Foundation: shared types + the single loaded user32 handle. --
    -- Honest hard dependency. If this throws "module 'hs.foundation' not found", the
    -- substrate has not loaded yet -- foundation must load before hs.screen so its
    -- shared typedefs (RECT, HANDLE, HDC ...) exist for our cdef below.
    local host = require("hs.foundation")

    local U = (host.C and host.C.user32) or ffi.load("user32")

    -- DPI: GetMonitorInfoA returns PHYSICAL pixels once the process is DPI-aware. We
    -- report LOGICAL pixels (physical / scale) so the rest of the app keeps the same
    -- coordinate space it had when DPI-unaware; canvas/webview re-apply the scale when
    -- they create windows. With awareness off scale is 1.0 and this is a no-op.
    local dpiscale = require("hs.dpiscale")
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

-- DisplayConfig surface for friendly monitor names --
    local displayDecls = {
        "typedef struct { DWORD LowPart; LONG HighPart; } MS_LUID;",
        "typedef struct { MS_LUID adapterId; unsigned int id; unsigned int modeInfoIdx; unsigned int statusFlags; } MS_DC_PATH_SOURCE;",
        "typedef struct { MS_LUID adapterId; unsigned int id; unsigned int modeInfoIdx; int outputTechnology; int rotation; int scaling; unsigned int refreshNum; unsigned int refreshDen; int scanLineOrdering; BOOL targetAvailable; unsigned int statusFlags; } MS_DC_PATH_TARGET;",
        "typedef struct { MS_DC_PATH_SOURCE sourceInfo; MS_DC_PATH_TARGET targetInfo; unsigned int flags; } MS_DC_PATH_INFO;",
        "typedef struct { int infoType; unsigned int id; MS_LUID adapterId; BYTE body[48]; } MS_DC_MODE_INFO;",
        "typedef struct { int type; unsigned int size; MS_LUID adapterId; unsigned int id; } MS_DC_HEADER;",
        "typedef struct { MS_DC_HEADER header; unsigned short viewGdiDeviceName[32]; } MS_DC_SOURCE_NAME;",
        "typedef struct { MS_DC_HEADER header; unsigned int flags; int outputTechnology; unsigned short edidManufactureId; unsigned short edidProductCodeId; unsigned int connectorInstance; unsigned short monitorFriendlyDeviceName[64]; unsigned short monitorDevicePath[128]; } MS_DC_TARGET_NAME;",
        "typedef struct { DWORD cb; char DeviceName[32]; char DeviceString[128]; DWORD StateFlags; char DeviceID[128]; char DeviceKey[128]; } MS_DISPLAY_DEVICEA;",
        "LONG GetDisplayConfigBufferSizes(unsigned int, unsigned int*, unsigned int*);",
        "LONG QueryDisplayConfig(unsigned int, unsigned int*, MS_DC_PATH_INFO*, unsigned int*, MS_DC_MODE_INFO*, void*);",
        "LONG DisplayConfigGetDeviceInfo(MS_DC_HEADER*);",
        "BOOL EnumDisplayDevicesA(LPCSTR, DWORD, MS_DISPLAY_DEVICEA*, DWORD);",
        "int WideCharToMultiByte(unsigned int, unsigned long, const unsigned short*, int, char*, int, const char*, BOOL*);",
    }
    for _, decl in ipairs(displayDecls) do pcall(ffi.cdef, decl) end
-- END --

-- Constants --
    local QDC_ONLY_ACTIVE_PATHS = 0x00000002
    local DC_GET_SOURCE_NAME    = 1
    local DC_GET_TARGET_NAME    = 2
    local CP_UTF8               = 65001
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

    -- :name() -> the monitor's friendly name, or the Win32 device path. --
        function Screen:name()
            return self.friendlyName or self.deviceName
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

    -- :snapshot([rect]) -> image of the screen, or of rect relative to the screen origin
    function Screen:snapshot(rect)
        local s = dpiscale.get()
        local m = self.monitor
        local rx = rect and rect.x or 0
        local ry = rect and rect.y or 0
        local rw = rect and rect.w or m.w
        local rh = rect and rect.h or m.h

        local px = math.floor((m.x + rx) * s + 0.5)
        local py = math.floor((m.y + ry) * s + 0.5)
        local pw = math.max(math.floor(rw * s + 0.5), 1)
        local ph = math.max(math.floor(rh * s + 0.5), 1)

        return require("hs.image")._captureScreen(px, py, pw, ph)
    end
-- END --

-- Enumeration --
    -- Collected fresh on each allScreens() call. The callback pushes into this table.
    local collected = {}

    local function enumProcFn(hMonitor, _hdc, _lprc, _lparam)
        pcall(function()
            local mi = ffi.new("MONITORINFOEXA")
            mi.cbSize = ffi.sizeof("MONITORINFOEXA")

            if U.GetMonitorInfoA(hMonitor, mi) ~= 0 then
                local m = mi.rcMonitor
                local w = mi.rcWork
                local s = dpiscale.get()   -- physical -> logical

                collected[#collected + 1] = {
                    deviceName = ffi.string(mi.szDevice),
                    primary    = (tonumber(mi.dwFlags) % 2) == 1,  -- PRIMARY is bit 0
                    monitor    = { x = m.left/s, y = m.top/s, w = (m.right - m.left)/s, h = (m.bottom - m.top)/s },
                    work       = { x = w.left/s, y = w.top/s, w = (w.right - w.left)/s, h = (w.bottom - w.top)/s },
                }
            end
        end)

        return 1  -- TRUE: keep enumerating
    end
    local enumProc = ffi.cast("MONITORENUMPROC", enumProcFn)

    -- Friendly names --
        local K = host.C and host.C.kernel32

        local function narrow(wide)
            if K == nil or wide[0] == 0 then return nil end
            local need = K.WideCharToMultiByte(CP_UTF8, 0, wide, -1, nil, 0, nil, nil)
            if need <= 1 then return nil end
            local buf = ffi.new("char[?]", need)
            K.WideCharToMultiByte(CP_UTF8, 0, wide, -1, buf, need, nil, nil)
            return ffi.string(buf)
        end

        -- Maps GDI device path to the EDID monitor name through DisplayConfig
        local function displayConfigNames()
            local names = {}
            local nPaths = ffi.new("unsigned int[1]")
            local nModes = ffi.new("unsigned int[1]")
            if U.GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, nPaths, nModes) ~= 0 then return names end
            if nPaths[0] == 0 then return names end

            local paths = ffi.new("MS_DC_PATH_INFO[?]", nPaths[0])
            local modes = ffi.new("MS_DC_MODE_INFO[?]", math.max(nModes[0], 1))
            if U.QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, nPaths, paths, nModes, modes, nil) ~= 0 then return names end

            for i = 0, nPaths[0] - 1 do
                local p = paths[i]
                local src = ffi.new("MS_DC_SOURCE_NAME")
                src.header.type = DC_GET_SOURCE_NAME
                src.header.size = ffi.sizeof("MS_DC_SOURCE_NAME")
                src.header.adapterId = p.sourceInfo.adapterId
                src.header.id = p.sourceInfo.id

                local tgt = ffi.new("MS_DC_TARGET_NAME")
                tgt.header.type = DC_GET_TARGET_NAME
                tgt.header.size = ffi.sizeof("MS_DC_TARGET_NAME")
                tgt.header.adapterId = p.targetInfo.adapterId
                tgt.header.id = p.targetInfo.id

                if U.DisplayConfigGetDeviceInfo(ffi.cast("MS_DC_HEADER*", src)) == 0
                    and U.DisplayConfigGetDeviceInfo(ffi.cast("MS_DC_HEADER*", tgt)) == 0 then
                    local device = narrow(src.viewGdiDeviceName)
                    local friendly = narrow(tgt.monitorFriendlyDeviceName)
                    if device and friendly and names[device] == nil then names[device] = friendly end
                end
            end
            return names
        end

        -- The monitor's device string from EnumDisplayDevices, or nil
        local function deviceString(deviceName)
            local dd = ffi.new("MS_DISPLAY_DEVICEA")
            dd.cb = ffi.sizeof("MS_DISPLAY_DEVICEA")
            if U.EnumDisplayDevicesA(deviceName, 0, dd, 0) == 0 then return nil end
            local str = ffi.string(dd.DeviceString)
            return str ~= "" and str or nil
        end

        local nameCache = { key = nil, names = {} }

        -- Fills friendlyName on each raw record, re-querying only when the monitor set changes
        local function nameScreens(raws)
            local devices = {}
            for i, r in ipairs(raws) do devices[i] = r.deviceName end
            local key = table.concat(devices, "|")

            if nameCache.key ~= key then
                local ok, names = pcall(displayConfigNames)
                if not ok then names = {} end
                for _, r in ipairs(raws) do
                    if names[r.deviceName] == nil then
                        local okDev, dev = pcall(deviceString, r.deviceName)
                        names[r.deviceName] = okDev and dev or nil
                    end
                end
                nameCache.key = key
                nameCache.names = names
            end

            for _, r in ipairs(raws) do r.friendlyName = nameCache.names[r.deviceName] end
        end
    -- END --

    -- Fallback single screen from GetSystemMetrics, mirroring the spike's assumption. --
        -- Used only if EnumDisplayMonitors yields nothing (rare: session 0, headless).
        local function fallbackScreen()
            local s = dpiscale.get()   -- physical -> logical
            local w = U.GetSystemMetrics(SM_CXSCREEN) / s
            local h = U.GetSystemMetrics(SM_CYSCREEN) / s
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
            nameScreens(raws)

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

    -- hs.screen.watcher: fires when the monitor layout changes --
        local watcherProto = {}

        watcherProto.__index = watcherProto

        screen.watcher = {}

        -- Returns one string that changes whenever a monitor is added, removed or resized
        local function layoutKey()
            local parts = {}

            for _, s in ipairs(screen.allScreens()) do
                local f = s:fullFrame()

                parts[#parts + 1] = string.format("%s:%d,%d,%d,%d", s:name(), f.x, f.y, f.w, f.h)
            end

            return table.concat(parts, "|")
        end

        -- Builds a watcher that calls fn with no arguments on a layout change
        function screen.watcher.new(fn)
            return setmetatable({
                _fn = fn,
                _timer = nil
            }, watcherProto)
        end

        -- Alias of new, matching Hammerspoon's active-screen variant
        function screen.watcher.newWithActiveScreen(fn)
            return screen.watcher.new(fn)
        end

        -- Starts polling the monitor layout
        function watcherProto:start()
            if self._timer then return self end

            local key = layoutKey()

            self._timer = require("hs.timer").doEvery(1, function()
                local now = layoutKey()

                if now == key then return end

                key = now

                pcall(self._fn)
            end)

            return self
        end

        -- Stops polling
        function watcherProto:stop()
            if self._timer then
                self._timer:stop()

                self._timer = nil
            end

            return self
        end
    -- END --
-- END --

return screen
