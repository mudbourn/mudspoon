-- hs.sound --
    -- Each sound plays in its own hs.soundhelper child process, so concurrent
    -- sounds mix and the input hook thread never blocks.
    -- The stop callback fires when the child exits or is stopped.
    -- Volume is passed to the child at :play(). Looping respawns the child.
    -- currentTime reports elapsed play time and a set value shifts the report.
    -- device is stored and playback uses the default device.
    -- getByName returns nil because Windows has no system sound registry.
-- END --

local ffi  = require("ffi")
local host = require("hs.foundation")
local task = require("hs.task")

-- Locate our own interpreter + the helper script --
    -- The host process IS luajit.exe, so GetModuleFileNameA(NULL) yields the exact
    -- interpreter to relaunch for the helper -- no PATH assumption, no launcher env var.
    ffi.cdef[[ unsigned long GetModuleFileNameA(void*, char*, unsigned long); ]]
    local K = host.C.kernel32

    local function selfExe()
        local buf = ffi.new("char[?]", 1024)
        local n   = K.GetModuleFileNameA(nil, buf, 1024)
        if n and n > 0 then return ffi.string(buf, n) end
        return "luajit"                      -- fall back to PATH resolution
    end
    local LUAJIT = selfExe()

    -- hs.soundhelper.lua sits next to this file.
    local thisFile   = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    local HELPER     = thisFile:gsub("[^/\\]+$", "") .. "soundhelper.lua"
-- END --

local sound = {}

-- Sound object --
    local Sound = {}
    Sound.__index = Sound

    -- Fire the end-of-play callback once (natural exit OR :stop()).
    local function fireStop(self)
        if self._cb and not self._fired then
            self._fired = true
            local cb = self._cb
            pcall(function() cb(self, "stop") end)
        end
    end

    function Sound:setCallback(fn)
        self._cb = (type(fn) == "function") and fn or nil
        return self
    end

    -- volume in 0..1 (ms.sound passes soundVolume/100). Stored; handed to the child at
    -- :play() time (a live child's volume is fixed for its short life -- fine for sfx).
    function Sound:volume(v)
        if v == nil then return self._volume end
        self._volume = math.max(0, math.min(1, v))
        return self
    end

    function Sound:play()
        -- A fresh play supersedes this object's own prior play (same handle = same sound).
        self._stopping = true
        if self._task and self._task:isRunning() then
            pcall(function() self._task:terminate() end)
        end
        self._fired = false
        self._task  = nil
        self._stopping = false

        local volArg = tostring(math.floor((self._volume or 1) * 100 + 0.5))
        local t = task.new(LUAJIT, function(_code)
            if self._loop and not self._stopping then
                self._offset = 0
                self:play()
                return
            end
            self._offset = 0
            fireStop(self)
        end, { HELPER, volArg, self._path })
        if t and t:start() then
            self._task = t
            self._startedAt = host.now()
        else
            -- Could not spawn the helper: honour a pending callback so a synchronous
            -- ms.sound coroutine isn't left yielded forever.
            fireStop(self)
        end
        return self
    end

    function Sound:stop()
        self._stopping = true
        if self._task and self._task:isRunning() then
            pcall(function() self._task:terminate() end)   -- fires doneFn -> fireStop
        else
            fireStop(self)                                 -- nothing running; unblock waiters
        end
        return self
    end

    function Sound:isPlaying()
        return (self._task and self._task:isRunning()) or false
    end

    -- :duration() -- length in seconds, or nil when it cannot be read --
        -- NSSound reports this on macOS. mudscript reads it to hold the exit curtain
        -- open for the shutdown and restart sounds. Only WAV is parsed here (the
        -- sounds on that path are WAV): duration is the data chunk size over the fmt
        -- chunk byte rate. Any non-WAV or malformed header returns nil, matching the
        -- "unknown" contract the caller already guards for.
        local function readU32LE(s, i)
            local a, b, c, d = s:byte(i, i + 3)
            if not d then return nil end
            return a + b * 256 + c * 65536 + d * 16777216
        end

        function Sound:duration()
            local f = io.open(self._path, "rb")
            if not f then return nil end

            local head = f:read(12)
            if not head or #head < 12
                or head:sub(1, 4) ~= "RIFF" or head:sub(9, 12) ~= "WAVE" then
                f:close()
                return nil
            end

            local byteRate = nil
            local dataSize = nil

            while true do
                local ch = f:read(8)
                if not ch or #ch < 8 then break end
                local id   = ch:sub(1, 4)
                local size = readU32LE(ch, 5)
                if not size then break end

                if id == "fmt " then
                    local body = f:read(size)
                    if body and #body >= 12 then byteRate = readU32LE(body, 9) end
                elseif id == "data" then
                    dataSize = size
                    break
                else
                    f:seek("cur", size + (size % 2))
                end
            end

            f:close()

            if byteRate and byteRate > 0 and dataSize and dataSize > 0 then
                return dataSize / byteRate
            end
            return nil
        end
    -- END --

    -- Loops while true. A looping sound replays itself until :stop()
    function Sound:loopSound(v)
        if v == nil then return self._loop end
        self._loop = v and true or false
        return self
    end

    -- Playback position in seconds, and a position applied from the next :play()
    function Sound:currentTime(t)
        if t ~= nil then
            self._offset = math.max(0, t)
            return self
        end
        if not self:isPlaying() then return self._offset or 0 end
        local elapsed = (host.now() - self._startedAt) / 1000 + (self._offset or 0)
        local d = self:duration()
        if self._loop and d and d > 0 then return elapsed % d end
        return elapsed
    end

    -- Output device name. Playback always uses the default device
    function Sound:device(name)
        if name == nil then return self._device end
        self._device = name
        return self
    end

    function Sound:name()
        return self._path
    end
-- END --

-- Constructors --
    local function exists(path)
        local f = io.open(path, "rb")
        if f then f:close(); return true end
        return false
    end

    local function make(path)
        return setmetatable({
            _path   = path,
            _volume = 1,
            _cb     = nil,
            _fired  = false,
            _task   = nil,
            _loop   = false,
            _offset = 0,
            _stopping = false,
        }, Sound)
    end

    function sound.getByFile(path)
        if type(path) ~= "string" or not exists(path) then return nil end
        return make(path)
    end

    -- No Windows system-sound-by-name registry: nil (mudscript's `or` fallback logs).
    function sound.getByName(_name) return nil end

    function sound.soundTypes() return { "wav", "mp3", "m4a", "aiff", "aif", "aac", "caf" } end
-- END --

return sound
