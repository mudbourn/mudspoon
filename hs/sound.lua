-- hs.sound  (Win32, one helper process per sound -- mixes, never stalls input) --
    -- Hammerspoon's hs.sound plays an NSSound. mudscript drives it through ms.sound /
    -- ms.playSlot:
    --   hs.sound.getByFile(path) or hs.sound.getByName(path)  -> sound | nil
    --   sound:volume(0..1) : sound:play() : sound:stop()
    --   sound:setCallback(fn)  -- fn(sound,"stop") when playback ends (drives the
    --                             coroutine-resume path in ms.sound's synchronous mode)
    --
    -- WHY A HELPER PROCESS -- the mouse-stall fix that still mixes:
    --   The low-level input hooks (hs.foundation's WH_MOUSE_LL / WH_KEYBOARD_LL) run ON
    --   THE PUMP THREAD, and Windows stalls system-wide input whenever that thread is
    --   blocked past LowLevelHooksTimeout. Every Windows audio call that can MIX sounds
    --   (MCI) is synchronous and costs 15-45ms per command on the pump thread -- so an
    --   in-process MCI backend hitched the mouse. The one instant call, PlaySound, is
    --   single-stream PER PROCESS, so in-process it could not overlap sounds (a new one
    --   cut the previous).
    --
    --   The escape from that bind: play each sound in its OWN short-lived child process
    --   (hs.soundhelper, run by this same luajit.exe). The child blocks on PlaySound; the
    --   host thread only pays a CreateProcess (~1-5ms), so input never stalls. And because
    --   PlaySound's single-stream limit is per PROCESS, N concurrent children = N streams
    --   the OS mixes -- overlap is back. A sound cutting only ITS OWN prior instance falls
    --   out naturally: ms.playSlot :stop()s the previous handle, which terminates that one
    --   child; a different sound is a different child and plays alongside.
    --
    --   Cost of the trade: ~20-40ms of process+interpreter startup before a sound is
    --   audible, and one transient process per sfx. Accepted to keep input responsive.
    --
    -- END-OF-PLAY: the child exits when the sound finishes, so hs.task's doneFn is the
    -- real end event -- it fires the "stop" callback (used by ms.sound's synchronous mode
    -- to resume a yielded coroutine). :stop() terminates the child, which also fires it.
    --
    -- VOLUME: passed to the child as 0..100; the child sets its own process wave volume,
    -- so ms.soundVolume applies without any cross-talk between overlapping sounds.
    --
    -- getByName has no Windows analogue -> nil (mudscript's `or` fallback then logs).
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
        if self._task and self._task:isRunning() then
            pcall(function() self._task:terminate() end)
        end
        self._fired = false
        self._task  = nil

        local volArg = tostring(math.floor((self._volume or 1) * 100 + 0.5))
        local t = task.new(LUAJIT, function(_code)
            fireStop(self)                   -- child exited => playback ended (or killed)
        end, { HELPER, volArg, self._path })
        if t and t:start() then
            self._task = t
        else
            -- Could not spawn the helper: honour a pending callback so a synchronous
            -- ms.sound coroutine isn't left yielded forever.
            fireStop(self)
        end
        return self
    end

    function Sound:stop()
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

    -- hs parity no-ops (mudscript sets these but they have no per-sound analogue here).
    function Sound:loopSound(_) return self end
    function Sound:device(_)    return self end
    function Sound:name()       return self._path end
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
