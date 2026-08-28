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
            -- imagePath can fail transiently (handle not yet openable early in a
            -- process's life, momentary access denial). Only cache a successful
            -- lookup; on failure leave _name nil so the next call retries rather
            -- than pinning a permanent false.
            local b = baseName(imagePath(self._pid))
            if b then
                b = b:gsub("%.[eE][xX][eE]$", "")
                self._name = b
            end
            return b
        end
        return self._name
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

    -- hs.application.watcher -- app activation / launch / terminate / show / hide.
    -- Backed by foundation's WinEvent source (host.onWinEvent). The callback fires as
    -- fn(appName, eventType, appObject), matching Hammerspoon.
    --
    -- Windows has no per-application activation notion the way macOS does, so we derive
    -- app-level events from window-level ones:
    --   activated / deactivated : EVENT_SYSTEM_FOREGROUND (foreground window changed);
    --                             the app owning the new front window is activated, the
    --                             previous one deactivated.
    --   launched / terminated   : first top-level window a pid opens => launched; the
    --                             last one it closes (or the process exiting) =>
    --                             terminated. Seeded at start() from currently-open
    --                             windows so already-running apps don't spuriously
    --                             report launched/terminated.
    -- `launching`, `hidden`, `unhidden` have no faithful Win32 analog and never fire:
    -- there is no pre-launch signal, and Windows has no application-level hide (a
    -- top-level window SHOW/HIDE is per-window paint churn -- one app launch emits a
    -- dozen of them -- so mapping those to app hidden/unhidden is noise, not signal).
    -- The constants stay for API compatibility; only launched/terminated/activated/
    -- deactivated actually fire.
    local pidBufW = ffi.new("DWORD[1]")
    local function pidOfHwnd(hwnd)
        if hwnd == nil then return nil end
        pidBufW[0] = 0
        U.GetWindowThreadProcessId(hwnd, pidBufW)
        local p = tonumber(pidBufW[0])
        return (p ~= 0) and p or nil
    end

    local watcherProto = {}
    watcherProto.__index = watcherProto

    function watcherProto:start()
        if self._unsub then return self end
        self._front = nil   -- pid of the last-activated app
        self._known = {}     -- pid -> true for every app we currently know owns a window
        self._names = {}     -- pid -> last-known name, so terminated can name a dead pid
        self._lastSweep = 0  -- host.now() of the last isRunning sweep (throttle)
        local W = host.winEvents

        -- Register a pid as a known windowed app, caching its name while the process is
        -- alive (once it exits the name is unrecoverable from the pid alone). Only apps
        -- we can actually name are tracked -- an unnameable window is a system/host
        -- surface whose termination is noise to consumers. Returns the name, or nil if
        -- it could not be named (and was therefore not registered).
        local function noteApp(pid)
            if not pid then return nil end
            if self._known[pid] then return self._names[pid] end
            local n = newApp(pid):name()
            if not n then return nil end
            self._known[pid] = true
            self._names[pid] = n
            return n
        end

        -- Terminated is detected by PROCESS DEATH, not by matching window handles:
        -- packaged/multi-window apps tear down many top-level windows whose HWNDs never
        -- line up with the one that fired "launched", and a force-kill sends no clean
        -- destroys at all. So on any (throttled) event we sweep the known-app set and
        -- report any pid whose process has actually exited. A foreground change always
        -- accompanies an app closing, so this catches force-kills even on a quiet desktop.
        local function sweepDead(fn)
            local now = host.now()
            if now - self._lastSweep < 200 then return end
            self._lastSweep = now
            for pid in pairs(self._known) do
                if not newApp(pid):isRunning() then
                    local name = self._names[pid]
                    self._known[pid] = nil
                    self._names[pid] = nil
                    if pid == self._front then self._front = nil end
                    -- appObject wraps a dead pid: name() would fail, so pass the cache.
                    fn(name, application.watcher.terminated, newApp(pid))
                end
            end
        end

        -- Seed from the current desktop so pre-existing apps aren't seen as launching,
        -- but ARE eligible for terminated if they later exit.
        local okwin, win = pcall(require, "hs.window")
        if okwin and type(win) == "table" and type(win._enumTopLevel) == "function" then
            for _, hwnd in ipairs(win._enumTopLevel()) do
                noteApp(pidOfHwnd(hwnd))
            end
        end
        self._front = pidOfHwnd(U.GetForegroundWindow())

        self._unsub = host.onWinEvent(function(event, hwnd, idObject, idChild)
            local fn = self._fn
            if not fn then return end
            sweepDead(fn)  -- throttled process-death detection on any activity

            if event == W.foreground then
                local pid = pidOfHwnd(hwnd)
                if not pid or pid == self._front then return end
                if self._front then
                    local old = newApp(self._front)
                    fn(old:name(), application.watcher.deactivated, old)
                end
                self._front = pid
                noteApp(pid)
                local app = newApp(pid)
                fn(app:name(), application.watcher.activated, app)
                return
            end

            -- Top-level window objects only (child controls / caret / cursor excluded).
            if idObject ~= W.OBJID_WINDOW or idChild ~= W.CHILDID_SELF then return end

            -- A new top-level window from a pid we haven't named yet is a launch.
            -- (objectDestroy needs no branch: sweepDead above turns real process
            -- exits into terminated, whatever window handles were involved.)
            if event == W.objectCreate then
                local pid = pidOfHwnd(hwnd)
                if pid and not self._known[pid] then
                    local n = noteApp(pid)
                    if n then fn(n, application.watcher.launched, newApp(pid)) end
                end
            end
        end)
        return self
    end

    function watcherProto:stop()
        if self._unsub then self._unsub(); self._unsub = nil end
        self._known = nil
        self._names = nil
        return self
    end

    application.watcher = {
        -- Event-type constants (values are arbitrary but must be stable + distinct).
        launching   = 0,   -- no Win32 analog; never fires (see note above)
        launched    = 1,
        terminated  = 2,
        hidden      = 3,
        unhidden    = 4,
        activated   = 5,
        deactivated = 6,
        new = function(fn)
            -- fn(appName, eventType, appObject) is called on each event once :start()'d.
            return setmetatable({ _fn = fn }, watcherProto)
        end,
    }
-- END --

return application
