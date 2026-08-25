-- hs.application  (leaf) --
    -- Process/application objects, matching Hammerspoon's `hs.application`. First
    -- slice: enough for mac/ to resolve its target app, read its name/pid, find its
    -- main window, and activate it.
    --
    -- Depends on FOUNDATION for shared FFI TYPES only, and on hs.window for
    -- top-level window enumeration (the seam window._enumTopLevel / _pidOf). Lazy
    -- requires break the load-time cycle (window:application() reaches back here).
    --
    -- WINDOWS HAS NO BUNDLE ID. :bundleID() returns the exe basename (e.g.
    -- "RobloxPlayerBeta.exe") -- the closest stable per-app identifier -- or nil if
    -- it can't be read. Documented choice; mac/ only uses it for debug display.
    --
    -- RIG-ONLY: every Win32 call can only be verified on the physical Windows
    -- console. Keep ffi.load behind foundation so `loadfile` parses on the mac.
-- END --

local ffi = require("ffi")

-- Foundation: shared types + the single loaded user32/kernel32. --
    local host = require("hs.foundation")
    local U = (host.C and host.C.user32)   or ffi.load("user32")
    local K = (host.C and host.C.kernel32) or ffi.load("kernel32")
-- END --

-- Own FFI surface (functions only; shared types come from Foundation) --
    -- QueryFullProcessImageNameA lives in kernel32 (Vista+). We open the process with
    -- PROCESS_QUERY_LIMITED_INFORMATION (0x1000), which succeeds for most processes
    -- from a normal-integrity caller without SeDebug.
    ffi.cdef[[
HANDLE OpenProcess(DWORD, BOOL, DWORD);
BOOL   CloseHandle(HANDLE);
BOOL   QueryFullProcessImageNameA(HANDLE, DWORD, char*, DWORD*);
HWND   GetForegroundWindow(void);
DWORD  GetWindowThreadProcessId(HWND, DWORD*);
BOOL   SetForegroundWindow(HWND);
]]
-- END --

-- Constants --
    local PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
-- END --

-- Process image path -> basename (best-effort; nil on failure) --
    local pathBuf = ffi.new("char[?]", 1024)
    local sizeBuf = ffi.new("DWORD[1]")
    local fgPidBuf = ffi.new("DWORD[1]")

    -- Full exe path for a pid, or nil.
    local function imagePath(pid)
        if not pid then return nil end
        local h = K.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid)
        if h == nil then return nil end
        sizeBuf[0] = 1024
        local ok = K.QueryFullProcessImageNameA(h, 0, pathBuf, sizeBuf)
        K.CloseHandle(h)
        if ok == 0 then return nil end
        return ffi.string(pathBuf, tonumber(sizeBuf[0]))
    end

    -- "C:\...\Foo.exe" -> "Foo.exe". Handles both slash flavours.
    local function baseName(path)
        if not path then return nil end
        return (path:gsub("^.*[/\\]", ""))
    end
-- END --

-- Application object --
    local App = {}
    App.__index = App

    -- Wrap a pid. Name/path resolved lazily and cached.
    local function newApp(pid)
        if not pid then return nil end
        return setmetatable({ _pid = pid }, App)
    end

    -- :pid() -> process id (number).
    function App:pid()
        return self._pid
    end

    -- :name() -> exe basename WITHOUT extension (Hammerspoon reports app display
    -- names sans ".app"; the Windows analog is the exe name without ".exe"). mac/
    -- compares this against target names like "RobloxPlayerBeta", so strip the ext.
    function App:name()
        if self._name == nil then
            local b = baseName(imagePath(self._pid))
            if b then b = b:gsub("%.[eE][xX][eE]$", "") end
            self._name = b or false
        end
        return self._name or nil
    end

    -- :title() -> alias of :name() (Windows has no separate app title).
    function App:title()
        return self:name()
    end

    -- :bundleID() -> exe basename WITH extension, or nil. See header note: Windows
    -- has no bundle identifier; this is the closest stable per-app string.
    function App:bundleID()
        return baseName(imagePath(self._pid))
    end

    -- :path() -> full exe path, or nil.
    function App:path()
        return imagePath(self._pid)
    end

    -- :allWindows() -> visible top-level windows owned by this process.
    function App:allWindows()
        local ok, win = pcall(require, "hs.window")
        if not ok or type(win) ~= "table" or type(win._enumTopLevel) ~= "function" then
            return {}
        end
        local out = {}
        for _, hwnd in ipairs(win._enumTopLevel()) do
            if win._pidOf(hwnd) == self._pid and win._isVisible(hwnd) then
                out[#out + 1] = win._newWindow(hwnd)
            end
        end
        return out
    end

    -- :mainWindow() -> the process's principal window. Best-effort: the first
    -- visible top-level window it owns that has a non-empty title, else the first
    -- visible one. (Stock Hammerspoon uses AXMainWindow; Win32 has no direct analog,
    -- so this heuristic stands in.) RIG-VERIFY it picks the game window for Roblox.
    function App:mainWindow()
        local ok, win = pcall(require, "hs.window")
        if not ok or type(win) ~= "table" or type(win._enumTopLevel) ~= "function" then
            return nil
        end
        local firstVisible
        for _, hwnd in ipairs(win._enumTopLevel()) do
            if win._pidOf(hwnd) == self._pid and win._isVisible(hwnd) then
                if not firstVisible then firstVisible = hwnd end
                if win._titleOf(hwnd) ~= "" then
                    return win._newWindow(hwnd)
                end
            end
        end
        return firstVisible and win._newWindow(firstVisible) or nil
    end

    -- :isFrontmost() -> is a window of this process the foreground window?
    function App:isFrontmost()
        local hwnd = U.GetForegroundWindow()
        if hwnd == nil then return false end
        U.GetWindowThreadProcessId(hwnd, fgPidBuf)
        return tonumber(fgPidBuf[0]) == self._pid
    end

    -- :activate() -> bring the app's main window to the foreground. Callback-free
    -- (SetForegroundWindow), but subject to Windows foreground-lock rules -- may
    -- silently no-op from a background caller. RIG-VERIFY.
    function App:activate()
        local w = self:mainWindow()
        if w and w.focus then w:focus() end
        return self
    end

    -- :isRunning() -> true while the pid still resolves to a live image.
    function App:isRunning()
        return imagePath(self._pid) ~= nil
    end

    -- :kill() / :hide() -- not implemented (need TerminateProcess / ShowWindow on
    -- every window). Stubbed no-ops so a call site does not crash. TODO rig work.
    function App:kill() end
    function App:hide() end
    function App:unhide() end
-- END --

-- Public API --
    local application = {}

    -- hs.application.applicationForPID(pid) -> app object (the seam hs.window uses).
    function application.applicationForPID(pid)
        return newApp(pid)
    end

    -- hs.application.frontmostApplication() -> app owning the foreground window (nil).
    function application.frontmostApplication()
        local hwnd = U.GetForegroundWindow()
        if hwnd == nil then return nil end
        U.GetWindowThreadProcessId(hwnd, fgPidBuf)
        local pid = tonumber(fgPidBuf[0])
        if pid == 0 then return nil end
        return newApp(pid)
    end

    -- hs.application.get(hint) -> first running app matching by name (case-insensitive
    -- exact match on the exe basename sans ext, else substring). hint may also be a
    -- number, treated as a pid. Enumerates process ids via top-level windows -- so it
    -- finds apps that OWN a window (which is exactly what mac/ targets). A truly
    -- windowless process won't be found by this slice.
    function application.get(hint)
        if hint == nil then return nil end
        if type(hint) == "number" then
            local app = newApp(hint)
            return app:isRunning() and app or nil
        end

        local needle = tostring(hint):lower()
        local ok, win = pcall(require, "hs.window")
        if not ok or type(win) ~= "table" or type(win._enumTopLevel) ~= "function" then
            return nil
        end

        -- Collect distinct pids that own a top-level window.
        local seen, pids = {}, {}
        for _, hwnd in ipairs(win._enumTopLevel()) do
            local pid = win._pidOf(hwnd)
            if pid and not seen[pid] then
                seen[pid] = true
                pids[#pids + 1] = pid
            end
        end

        -- Prefer an exact name match; fall back to a substring match.
        local fuzzy
        for _, pid in ipairs(pids) do
            local app = newApp(pid)
            local n = app:name()
            if n then
                local ln = n:lower()
                if ln == needle then return app end
                if not fuzzy and ln:find(needle, 1, true) then fuzzy = app end
            end
        end
        return fuzzy
    end

    -- hs.application.find(hint) -> alias of get for this slice (stock returns a list
    -- for a pattern; mac/ uses the single-result shape).
    application.find = application.get

    -- hs.application.frontmostApplication alias some code spells .frontmost...
    -- (kept as the canonical name only; no extra alias needed).

    -- hs.application.watcher -- app activation/hide events. NOT wired to a real Win32
    -- event source yet (needs SetWinEventHook with an anchored WINEVENTPROC). Provide
    -- the CONSTANTS mac/ reads plus a no-op watcher object so watcher.new():start()
    -- does not crash; it simply never fires. TODO: real SetWinEventHook on the rig.
    local watcherProto = {}
    watcherProto.__index = watcherProto
    function watcherProto:start()  return self end
    function watcherProto:stop()   return self end

    application.watcher = {
        -- Event-type constants (values are arbitrary but must be stable + distinct).
        launching  = 0,
        launched   = 1,
        terminated = 2,
        hidden     = 3,
        unhidden   = 4,
        activated  = 5,
        deactivated = 6,
        new = function(_fn)
            -- _fn(appName, eventType, appObject) would be called on events; unused
            -- until a real event source is wired. Kept so the closure isn't GC-warned.
            return setmetatable({ _fn = _fn }, watcherProto)
        end,
    }
-- END --

return application
