-- hs.window  (leaf) --
    -- Top-level window objects, matching Hammerspoon's `hs.window`. First slice:
    -- the HOT PATH mac/ crashes without -- a real window object whose :frame()
    -- returns NUMERIC {x,y,w,h}. Two current crash sites depend on that:
    --   mac/lib/ms_devtools.lua:2031  math.floor(f.x/.y/.w/.h)
    --   mac/ms_core.lua:1845          f.x + f.w/2
    --
    -- Depends on FOUNDATION for shared FFI TYPES only (HWND, RECT, DWORD, BOOL,
    -- HANDLE, LPCSTR, UINT, LONG ...). Per the frozen cdef-ownership rule this
    -- module cdefs ONLY its own function prototypes + the one enum callback type,
    -- and never re-typedefs a shared type.
    --
    -- CONTRACT: coordinates are Win32 physical pixels, top-left origin, Y down --
    -- the same space hs.screen reports (see hs/screen.lua). :frame() returns a
    -- plain numeric table by default; if a REAL hs.geometry is loaded it wraps the
    -- result in geometry.rect(...) so callers get the richer type. mac/ only reads
    -- .x/.y/.w/.h, so the plain table is a sufficient fallback and MUST work when
    -- geometry is still the boot stub.
    --
    -- RIG-ONLY: every Win32 call below can only be verified on the physical
    -- Windows console. ffi.load("user32") cannot run on macOS -- keep it inside
    -- functions / behind foundation so `loadfile` parses clean on the mac.
-- END --

local ffi = require("ffi")

-- Foundation: shared types + the single loaded user32. --
    local host = require("hs.foundation")
    local U = (host.C and host.C.user32) or ffi.load("user32")
-- END --

-- Own FFI surface (functions + one callback type; shared types from Foundation) --
    ffi.cdef[[
typedef BOOL (__stdcall *WNDENUMPROC)(HWND, LPARAM);

HWND  GetForegroundWindow(void);
BOOL  SetForegroundWindow(HWND);
BOOL  GetWindowRect(HWND, RECT*);
int   GetWindowTextA(HWND, char*, int);
int   GetWindowTextLengthA(HWND);
DWORD GetWindowThreadProcessId(HWND, DWORD*);
BOOL  IsWindowVisible(HWND);
BOOL  IsWindow(HWND);
BOOL  IsIconic(HWND);
BOOL  IsZoomed(HWND);
BOOL  EnumWindows(WNDENUMPROC, LPARAM);
BOOL  BringWindowToTop(HWND);
BOOL  ShowWindow(HWND, int);
BOOL  SetWindowPos(HWND, HWND, int, int, int, int, UINT);
]]
-- END --

-- Constants --
    local SW_RESTORE     = 9
    local SW_MAXIMIZE    = 3

    -- SetWindowPos flags
    local SWP_NOZORDER   = 0x0004
    local SWP_NOACTIVATE = 0x0010
    local SWP_NOSIZE     = 0x0001
    local SWP_NOMOVE     = 0x0002
-- END --

-- Real hs.geometry resolver (memoized only once a REAL one is found) --
    -- During boot hs.geometry is a black-hole stub (see run_mudscript STUB_MODULES):
    -- it is callable and truthy, and geo.rect(...) returns the stub -- whose .x/.w
    -- are NOT numeric, which would re-break the very crash sites we exist to fix.
    -- So probe FUNCTIONALLY: only treat geometry as real if rect(0,0,2,2) yields a
    -- table with numeric w==2,x==0. Cache only a real hit; keep probing (cheap,
    -- require() is cached) until one appears (e.g. after geometry lands / a reload).
    local realGeo = nil
    local function geometry()
        if realGeo then return realGeo end
        local ok, geo = pcall(require, "hs.geometry")
        if ok and type(geo) == "table" and type(geo.rect) == "function" then
            local okp, r = pcall(geo.rect, 0, 0, 2, 2)
            if okp and type(r) == "table" and r.w == 2 and r.x == 0 then
                realGeo = geo
                return geo
            end
        end
        return nil
    end
-- END --

-- Low-level helpers (each takes a raw HWND cdata) --
    local rectBuf = ffi.new("RECT")
    local pidBuf  = ffi.new("DWORD[1]")

    -- Numeric {x,y,w,h} from GetWindowRect, or nil if the call fails.
    local function rectOf(hwnd)
        if hwnd == nil then return nil end
        if U.GetWindowRect(hwnd, rectBuf) == 0 then return nil end
        return {
            x = rectBuf.left,
            y = rectBuf.top,
            w = rectBuf.right - rectBuf.left,
            h = rectBuf.bottom - rectBuf.top,
        }
    end

    -- Owning process id (number) for a window, or nil.
    local function pidOf(hwnd)
        if hwnd == nil then return nil end
        U.GetWindowThreadProcessId(hwnd, pidBuf)
        return tonumber(pidBuf[0])
    end

    -- Window title text (may be ""), or "".
    local function titleOf(hwnd)
        if hwnd == nil then return "" end
        local len = U.GetWindowTextLengthA(hwnd)
        if len <= 0 then return "" end
        local buf = ffi.new("char[?]", len + 1)
        local n = U.GetWindowTextA(hwnd, buf, len + 1)
        if n <= 0 then return "" end
        return ffi.string(buf, n)
    end
-- END --

-- Window object --
    local Window = {}
    Window.__index = Window

    -- Wrap a raw HWND. The HWND cdata is kept as self._hwnd; a numeric form is
    -- stashed for :id() and equality-ish uses.
    local function newWindow(hwnd)
        if hwnd == nil then return nil end
        return setmetatable({
            _hwnd = hwnd,
            _id   = tonumber(ffi.cast("intptr_t", hwnd)),
        }, Window)
    end

    -- :frame() -> {x,y,w,h} numeric (or hs.geometry.rect when a real one is loaded)
    -- THE crash-site contract. Falls back to a zero rect rather than nil so callers
    -- doing arithmetic (f.x + f.w/2) never hit a nil index -- Hammerspoon's frame()
    -- also always returns a rect for a live window.
    function Window:frame()
        local r = rectOf(self._hwnd) or { x = 0, y = 0, w = 0, h = 0 }
        local geo = geometry()
        if geo then return geo.rect(r.x, r.y, r.w, r.h) end
        return r
    end

    -- :id() -> the HWND as a number (stable while the window lives).
    function Window:id()
        return self._id
    end

    -- :title() -> window caption text (possibly "").
    function Window:title()
        return titleOf(self._hwnd)
    end

    -- :isVisible() -> boolean (IsWindowVisible).
    function Window:isVisible()
        return U.IsWindowVisible(self._hwnd) ~= 0
    end

    -- :isStandard() -> best-effort true. A precise notion (has titlebar, not a
    -- tool window) needs GetWindowLong style bits; not required by mac/ yet.
    function Window:isStandard()
        return true
    end

    -- :isMinimized() / :isFullScreen() -- mac/ reads isFullScreen() for debug text.
    -- isFullScreen approximated as "maximized" (IsZoomed); true borderless-fullscreen
    -- detection needs a frame-vs-monitor compare, deferred.
    function Window:isMinimized()
        return U.IsIconic(self._hwnd) ~= 0
    end
    function Window:isFullScreen()
        return U.IsZoomed(self._hwnd) ~= 0
    end

    -- :application() -> hs.application wrapping the owning PID (or nil).
    -- Lazy-require to avoid a load-time cycle (application requires this module).
    function Window:application()
        local pid = pidOf(self._hwnd)
        if not pid then return nil end
        local ok, app = pcall(require, "hs.application")
        if not ok or type(app) ~= "table" or type(app.applicationForPID) ~= "function" then
            return nil
        end
        return app.applicationForPID(pid)
    end

    -- :pid() -> owning process id (convenience; not in stock hs.window but harmless).
    function Window:pid()
        return pidOf(self._hwnd)
    end

    -- :screen() -> the hs.screen this window is (mostly) on. Chosen by which screen
    -- frame contains the window centre; falls back to mainScreen(). mac/ calls
    -- win:screen():frame(), so this must return an object with :frame().
    function Window:screen()
        local ok, scr = pcall(require, "hs.screen")
        if not ok or type(scr) ~= "table" or type(scr.allScreens) ~= "function" then
            return nil
        end
        local f = rectOf(self._hwnd)
        local screens = scr.allScreens()
        if f then
            local cx, cy = f.x + f.w / 2, f.y + f.h / 2
            for _, s in ipairs(screens) do
                local sf = s:fullFrame()
                if cx >= sf.x and cx < sf.x + sf.w and cy >= sf.y and cy < sf.y + sf.h then
                    return s
                end
            end
        end
        return scr.mainScreen()
    end

    -- :focus() / :raise() -> bring the window forward. SetForegroundWindow is
    -- callback-free, so implement best-effort (restore if minimized, then raise).
    -- NOTE: Windows restricts who may call SetForegroundWindow (foreground-lock
    -- rules); it can silently no-op from a background process. RIG-VERIFY.
    function Window:focus()
        if U.IsIconic(self._hwnd) ~= 0 then U.ShowWindow(self._hwnd, SW_RESTORE) end
        U.BringWindowToTop(self._hwnd)
        U.SetForegroundWindow(self._hwnd)
        return self
    end
    Window.raise = Window.focus

    -- :move(point) / :setTopLeft(point) -> reposition, keep size. point = {x=,y=}
    -- (or a numeric-index {x,y}). Callback-free (SetWindowPos). RIG-VERIFY.
    function Window:setTopLeft(pt)
        local x = pt.x or pt[1] or 0
        local y = pt.y or pt[2] or 0
        U.SetWindowPos(self._hwnd, nil, x, y, 0, 0,
            SWP_NOZORDER + SWP_NOACTIVATE + SWP_NOSIZE)
        return self
    end
    Window.move = Window.setTopLeft

    -- :setSize(size) -> resize, keep position. size = {w=,h=}.
    function Window:setSize(sz)
        local w = sz.w or sz[1] or 0
        local h = sz.h or sz[2] or 0
        U.SetWindowPos(self._hwnd, nil, 0, 0, w, h,
            SWP_NOZORDER + SWP_NOACTIVATE + SWP_NOMOVE)
        return self
    end

    -- :setFrame(rect) -> move AND resize in one call. rect = {x,y,w,h}.
    function Window:setFrame(rc)
        local x = rc.x or 0
        local y = rc.y or 0
        local w = rc.w or 0
        local h = rc.h or 0
        U.SetWindowPos(self._hwnd, nil, x, y, w, h, SWP_NOZORDER + SWP_NOACTIVATE)
        return self
    end
-- END --

-- Enumeration (anchored callback; process lifetime) --
    -- EnumWindows takes a C callback the OS calls synchronously during the call.
    -- Per the foundation discipline, the ffi.cast callback is created ONCE at module
    -- scope so the GC can never free it mid-enumeration ("bad callback" panic). It
    -- only pushes raw HWNDs into `collected`; all filtering happens in Lua after.
    local collected = {}

    -- jit.off + pcall: never let a Lua error unwind across the FFI boundary (a throw,
    -- or an unwind out of JIT-compiled mcode, is a hard crash -- "bad callback").
    local function enumProcFn(hwnd, _lparam)
        pcall(function()
            collected[#collected + 1] = hwnd
        end)
        return 1  -- TRUE: keep enumerating
    end
    jit.off(enumProcFn, true)
    local enumProc = ffi.cast("WNDENUMPROC", enumProcFn)

    -- Raw list of every top-level HWND. Internal; callers get objects via allWindows.
    local function enumTopLevel()
        for i = #collected, 1, -1 do collected[i] = nil end  -- clear in place
        U.EnumWindows(enumProc, 0)
        -- Copy out so a re-entrant enum can't stomp the caller's list.
        local out = {}
        for i = 1, #collected do out[i] = collected[i] end
        return out
    end
    -- EnumWindows synchronously invokes enumProc; if this caller were JIT-compiled the
    -- callback would be entered from mcode -> "bad callback" panic (see hs.foundation's
    -- host.run). allWindows() is called often by the macro recorder, so keep it cold.
    jit.off(enumTopLevel)
-- END --

-- Public API --
    local window = {}

    -- hs.window.focusedWindow() / frontmostWindow() -> the foreground window (or nil).
    function window.focusedWindow()
        local hwnd = U.GetForegroundWindow()
        if hwnd == nil then return nil end
        return newWindow(hwnd)
    end
    window.frontmostWindow = window.focusedWindow

    -- hs.window.allWindows() -> visible top-level windows (best-effort standard set).
    -- Filters to visible windows with a non-empty title, which drops most tool/shadow
    -- windows -- close enough to Hammerspoon's "standard windows" for mac/'s needs.
    function window.allWindows()
        local out = {}
        for _, hwnd in ipairs(enumTopLevel()) do
            if U.IsWindowVisible(hwnd) ~= 0 and titleOf(hwnd) ~= "" then
                out[#out + 1] = newWindow(hwnd)
            end
        end
        return out
    end

    -- orderedWindows() -> same set (true front-to-back Z order needs GetTopWindow /
    -- GetWindow(GW_HWNDNEXT) walking; deferred, the set is what mac/ iterates).
    window.orderedWindows = window.allWindows

    -- hs.window.find(pattern) -> first window whose title OR owning app name matches
    -- the (plain, case-insensitive) substring. mac/ uses it as a target fallback.
    function window.find(pattern)
        if not pattern then return nil end
        local needle = tostring(pattern):lower()
        local okApp, appMod = pcall(require, "hs.application")
        local haveApp = okApp and type(appMod) == "table"
            and type(appMod.applicationForPID) == "function"
        for _, hwnd in ipairs(enumTopLevel()) do
            if U.IsWindowVisible(hwnd) ~= 0 then
                local t = titleOf(hwnd):lower()
                if t ~= "" and t:find(needle, 1, true) then
                    return newWindow(hwnd)
                end
                if haveApp then
                    local pid = pidOf(hwnd)
                    local app = pid and appMod.applicationForPID(pid) or nil
                    local n = app and app:name()
                    if n and n:lower():find(needle, 1, true) then
                        return newWindow(hwnd)
                    end
                end
            end
        end
        return nil
    end

    -- Internal seam hs.application reuses (mainWindow/allWindows for a pid).
    window._enumTopLevel = enumTopLevel
    window._newWindow    = newWindow
    window._pidOf        = pidOf
    window._titleOf      = titleOf
    window._isVisible    = function(hwnd) return U.IsWindowVisible(hwnd) ~= 0 end
-- END --

return window
