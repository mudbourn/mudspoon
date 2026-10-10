-- hs.application --
    -- Process objects over top-level windows. bundleID() is the exe basename.
    -- hide() minimizes every visible window and unhide() restores them.
-- END --

local ffi = require("ffi")

-- Foundation: shared types + the single loaded user32/kernel32. --
    local host = require("hs.foundation")
    local U = (host.C and host.C.user32)   or ffi.load("user32")
    local K = (host.C and host.C.kernel32) or ffi.load("kernel32")
-- END --

-- Own FFI surface (functions only; shared types come from Foundation) --
    ffi.cdef[[
HANDLE OpenProcess(DWORD, BOOL, DWORD);
BOOL   CloseHandle(HANDLE);
BOOL   QueryFullProcessImageNameA(HANDLE, DWORD, char*, DWORD*);
HWND   GetForegroundWindow(void);
DWORD  GetWindowThreadProcessId(HWND, DWORD*);
BOOL   SetForegroundWindow(HWND);
BOOL   PostMessageA(HWND, UINT, WPARAM, LPARAM);
BOOL   TerminateProcess(HANDLE, UINT);
BOOL   ShowWindow(HWND, int);
BOOL   IsIconic(HWND);
]]
-- END --

-- Constants --
    local PROCESS_QUERY_LIMITED_INFORMATION = 0x1000

    local PROCESS_TERMINATE = 0x0001

    local WM_CLOSE = 0x0010

    local SW_MINIMIZE = 6

    local SW_RESTORE = 9

    local HOST_NAME = "Hammerspoon"

    local HOST_BUNDLE_ID = "org.hammerspoon.Hammerspoon"

    local hostPid = host.pid
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
        if self._pid == hostPid then return HOST_NAME end
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
        if self._pid == hostPid then return HOST_BUNDLE_ID end
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

    -- Brings the main window to the foreground and returns whether one existed
    function App:activate()
        local w = self:mainWindow()
        if not w then return false end
        w:focus()
        return true
    end

    -- Returns 1 when the app owns a visible window or is the host, else 0
    function App:kind()
        if self._pid == hostPid then return 1 end
        return #self:allWindows() > 0 and 1 or 0
    end

    -- :isRunning() -> true while the pid still resolves to a live image.
    function App:isRunning()
        return imagePath(self._pid) ~= nil
    end

    -- Windows minimized by :hide(), keyed by pid
    local hiddenByPid = {}

    -- Posts WM_CLOSE to every visible window, the graceful quit
    function App:kill()
        for _, w in ipairs(self:allWindows()) do
            U.PostMessageA(w._hwnd, WM_CLOSE, 0, 0)
        end
    end

    -- Terminates the process outright
    function App:kill9()
        local h = K.OpenProcess(PROCESS_TERMINATE, 0, self._pid)
        if h == nil then return false end
        local ok = K.TerminateProcess(h, 1)
        K.CloseHandle(h)
        return ok ~= 0
    end

    -- Minimizes every visible window and remembers which ones
    function App:hide()
        local list = hiddenByPid[self._pid] or {}
        for _, w in ipairs(self:allWindows()) do
            if U.IsIconic(w._hwnd) == 0 then
                U.ShowWindow(w._hwnd, SW_MINIMIZE)
                list[#list + 1] = w._hwnd
            end
        end
        hiddenByPid[self._pid] = list
        return true
    end

    -- Restores the windows :hide() minimized
    function App:unhide()
        local list = hiddenByPid[self._pid] or {}
        for _, hwnd in ipairs(list) do
            U.ShowWindow(hwnd, SW_RESTORE)
        end
        hiddenByPid[self._pid] = nil
        return true
    end

    -- True when the app owns windows and all of them are minimized
    function App:isHidden()
        local ws = self:allWindows()
        if #ws == 0 then return false end
        for _, w in ipairs(ws) do
            if U.IsIconic(w._hwnd) == 0 then return false end
        end
        return true
    end

    -- Builds a uielement watcher fed by the shared WinEvent source for this app
    function App:newWatcher(fn, userdata)
        local win = require("hs.window")
        local app = self
        local pid = self._pid
        local W = host.winEvents
        local EV = require("hs.uielement").watcher
        local GWL_STYLE = -16
        local WS_CHILD = 0x40000000
        local rect = ffi.new("RECT")
        local wanted = {}
        local known = {}
        local unsub
        local watcher = {}

        -- Fires fn for one window with the mapped event name
        local function emit(hwnd, event)
            if not wanted[event] then return end

            fn(win._newWindow(hwnd), event, watcher, userdata)
        end

        -- Reads hwnd geometry and minimized state into one cached record
        local function sample(hwnd)
            if U.GetWindowRect(hwnd, rect) == 0 then return nil end

            return {
                x = rect.left,
                y = rect.top,
                w = rect.right - rect.left,
                h = rect.bottom - rect.top,
                min = U.IsIconic(hwnd) ~= 0,
            }
        end

        -- Maps one WinEvent to uielement watcher events for this pid
        local function onEvent(event, hwnd, idObject, idChild)
            if hwnd == nil or idObject ~= W.OBJID_WINDOW or idChild ~= W.CHILDID_SELF then return end
            if win._pidOf(hwnd) ~= pid then return end
            if (tonumber(U.GetWindowLongA(hwnd, GWL_STYLE)) & WS_CHILD) ~= 0 then return end

            local key = tonumber(ffi.cast("uintptr_t", hwnd))

            if event == W.objectCreate then
                emit(hwnd, EV.windowCreated)
            elseif event == W.locationChange then
                local now = sample(hwnd)
                local old = known[key]

                if not now then return end

                known[key] = now

                if not old then return end

                if now.min ~= old.min then
                    emit(hwnd, now.min and EV.windowMinimized or EV.windowUnminimized)
                elseif not now.min then
                    if now.w ~= old.w or now.h ~= old.h then
                        emit(hwnd, EV.windowResized)
                    end

                    if now.x ~= old.x or now.y ~= old.y then
                        emit(hwnd, EV.windowMoved)
                    end
                end
            end
        end

        -- Starts delivery for the given watcher event names
        function watcher:start(events)
            wanted = {}

            for _, name in ipairs(events or {}) do
                wanted[name] = true
            end

            known = {}

            for _, hwnd in ipairs(win._enumTopLevel()) do
                if win._pidOf(hwnd) == pid then
                    known[tonumber(ffi.cast("uintptr_t", hwnd))] = sample(hwnd)
                end
            end

            if not unsub then unsub = host.onWinEvent(onEvent) end

            return self
        end

        -- Unsubscribes and drops cached window state
        function watcher:stop()
            if unsub then
                unsub()
                unsub = nil
            end

            known = {}

            return self
        end

        -- Returns the application this watcher observes
        function watcher:element()
            return app
        end

        -- Returns the observed process id
        function watcher:pid()
            return pid
        end

        return watcher
    end
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
        if hint == hostPid or (type(hint) == "string" and hint:lower() == HOST_NAME:lower()) then
            return newApp(hostPid)
        end
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

    -- hs.application.runningApplications() -> apps owning top-level windows, plus the host
    function application.runningApplications()
        local out = { newApp(hostPid) }
        local ok, win = pcall(require, "hs.window")
        if not ok or type(win) ~= "table" or type(win._enumTopLevel) ~= "function" then
            return out
        end
        local seen = { [hostPid] = true }
        for _, hwnd in ipairs(win._enumTopLevel()) do
            local pid = win._pidOf(hwnd)
            if pid and not seen[pid] then
                seen[pid] = true
                out[#out + 1] = newApp(pid)
            end
        end
        return out
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
    --   hidden / unhidden       : every visible window of a pid becoming minimized,
    --                             and back to at least one restored window.
    -- `launching` has no Win32 analog and never fires.
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
        self._iconic = {}
        self._hidden = {}
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

            -- Reports hidden or unhidden when a known pid flips between all-minimized and not
            if event == W.locationChange or event == W.objectShow or event == W.objectHide then
                local pid = pidOfHwnd(hwnd)
                local key = tonumber(ffi.cast("uintptr_t", hwnd))
                local iconic = U.IsIconic(hwnd) ~= 0

                if pid and self._known[pid] and (event ~= W.locationChange or iconic ~= (self._iconic[key] or false)) then
                    self._iconic[key] = iconic

                    local app = newApp(pid)
                    local hidden = app:isHidden()

                    if hidden ~= (self._hidden[pid] or false) then
                        self._hidden[pid] = hidden
                        fn(app:name(), hidden and application.watcher.hidden or application.watcher.unhidden, app)
                    end
                end
            end

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
        self._iconic = nil
        self._hidden = nil
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
