-- hs.caffeinate: power, lock and screensaver watcher --

local ffi = require("ffi")

local host = require("hs.foundation")

local U = host.C.user32

-- Own FFI surface --
    for _, decl in ipairs({
        "HANDLE OpenInputDesktop(DWORD, BOOL, DWORD);",
        "BOOL SwitchDesktop(HANDLE);",
        "BOOL CloseDesktop(HANDLE);",
        "BOOL SystemParametersInfoA(UINT, UINT, void*, UINT);"
    }) do
        pcall(ffi.cdef, decl)
    end
-- END --

-- Constants --
    local DESKTOP_SWITCHDESKTOP = 0x0100
    local SPI_GETSCREENSAVERRUNNING = 0x0072
    local POLL_EVERY = 1
    local WAKE_GAP = 10
-- END --

local caffeinate = {}

local watcher = {
    systemDidWake = 0,
    systemWillSleep = 1,
    systemWillPowerOff = 2,
    screensDidSleep = 3,
    screensDidWake = 4,
    sessionDidResignActive = 5,
    sessionDidBecomeActive = 6,
    screensaverDidStart = 7,
    screensaverWillStop = 8,
    screensaverDidStop = 9,
    screensDidLock = 10,
    screensDidUnlock = 11
}

caffeinate.watcher = watcher

local watcherProto = {}

watcherProto.__index = watcherProto

-- Reports whether the input desktop is the locked secure desktop
local function isLocked()
    local desk = U.OpenInputDesktop(0, 0, DESKTOP_SWITCHDESKTOP)

    if desk == nil then return true end

    local switched = U.SwitchDesktop(desk) ~= 0

    U.CloseDesktop(desk)

    return not switched
end

-- Reports whether the screensaver is running
local function isSaverRunning()
    local flag = ffi.new("BOOL[1]")

    if U.SystemParametersInfoA(SPI_GETSCREENSAVERRUNNING, 0, flag, 0) == 0 then return false end

    return flag[0] ~= 0
end

-- Builds a watcher that calls fn with one event constant per change
function watcher.new(fn)
    return setmetatable({
        _fn = fn,
        _timer = nil
    }, watcherProto)
end

-- Starts polling the session state
function watcherProto:start()
    if self._timer then return self end

    local locked = isLocked()
    local saver = isSaverRunning()
    local last = os.time()

    self._timer = require("hs.timer").doEvery(POLL_EVERY, function()
        local now = os.time()

        if now - last > WAKE_GAP then pcall(self._fn, watcher.systemDidWake) end

        last = now

        local nowLocked = isLocked()

        if nowLocked ~= locked then
            locked = nowLocked

            pcall(self._fn, locked and watcher.screensDidLock or watcher.screensDidUnlock)

            pcall(self._fn, locked and watcher.sessionDidResignActive or watcher.sessionDidBecomeActive)
        end

        local nowSaver = isSaverRunning()

        if nowSaver ~= saver then
            saver = nowSaver

            pcall(self._fn, saver and watcher.screensaverDidStart or watcher.screensaverDidStop)
        end
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

return caffeinate
