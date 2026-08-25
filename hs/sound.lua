-- hs.sound  (Win32 MCI backend -- multi-format audio) --
    -- Hammerspoon's hs.sound plays an NSSound. mudscript drives it through ms.sound /
    -- ms.playSlot:
    --   hs.sound.getByFile(path) or hs.sound.getByName(path)  -> sound | nil
    --   sound:volume(0..1) : sound:play() : sound:stop()
    --   sound:setCallback(fn)  -- fn(sound,"stop") when playback ends (drives the
    --                             coroutine-resume path in ms.sound's synchronous mode)
    --
    -- Backed by MCI (mciSendStringA), NOT PlaySound: mudscript's soundExtensions are
    -- wav/aiff/aif/mp3/m4a/caf/aac, and PlaySound decodes only WAV -- so the startup
    -- slots (mostly mp3/m4a) were SILENT. MCI opens the file with the OS codec for its
    -- type, so every format mudscript ships plays. MCI also supports per-alias volume
    -- and lets us detect end-of-play, which PlaySound could not (so :volume actually
    -- applies and :setCallback can fire).
    --
    -- MODEL: each sound owns a unique MCI alias. :play() opens the file, sets volume,
    -- and starts async play, plus a ~100ms poll that (a) closes the alias when playback
    -- ends -- so devices are not leaked -- and (b) fires the "stop" callback if one is
    -- set. :stop() halts + closes + fires the callback (so a waiting coroutine resumes).
    -- getByName has no Windows analogue -> nil (mudscript's `or` fallback then logs).
    --
    -- CDEF OWNERSHIP: mciSendStringA (winmm) is owned here; base types from foundation.
    -- Commands quote the path so spaces are safe. Exotic formats still depend on the
    -- MCI driver installed for that type (wav/mp3 are always present; aac/m4a usually).
-- END --

local ffi = require("ffi")

local host = require("hs.foundation")

local okWinmm, WM = pcall(ffi.load, "winmm")
if not okWinmm then WM = nil end

-- Own FFI surface --
    ffi.cdef[[
unsigned int mciSendStringA(LPCSTR, char*, unsigned int, HWND);
]]
-- END --

-- MCI command helpers --
    local POLL_MS = 100

    -- Send one MCI command string. Returns (ok, replyString). ok = MCIERROR 0.
    local function mci(cmd)
        if not WM then return false, "" end
        local buf = ffi.new("char[?]", 256)
        local rc  = WM.mciSendStringA(ffi.cast("LPCSTR", cmd), buf, 256, nil)
        return rc == 0, ffi.string(buf)
    end

    -- Is the alias still sounding? `status <alias> mode` -> "playing"/"stopped"/...
    local function isPlaying(alias)
        local ok, mode = mci(string.format("status %s mode", alias))
        return ok and mode == "playing"
    end
-- END --

local sound = {}

-- Sound object --
    local Sound = {}
    Sound.__index = Sound

    local nextId = 1

    -- Tear down the MCI alias (idempotent) and fire the end callback once.
    local function finish(self, reason)
        if self._poll then self._poll:cancel(); self._poll = nil end
        if self._open then
            mci("close " .. self._alias)
            self._open = false
        end
        if self._cb and not self._fired then
            self._fired = true
            local cb = self._cb
            pcall(function() cb(self, reason or "stop") end)
        end
    end

    function Sound:setCallback(fn)
        self._cb = (type(fn) == "function") and fn or nil
        return self
    end

    -- volume in 0..1 (ms.sound passes soundVolume/100). MCI wants 0..1000.
    function Sound:volume(v)
        if v == nil then return self._volume end
        self._volume = v
        if self._open then
            mci(string.format("setaudio %s volume to %d", self._alias,
                              math.max(0, math.min(1000, math.floor(v * 1000 + 0.5)))))
        end
        return self
    end

    function Sound:play()
        if not WM then return self end
        finish(self, "stop")          -- stop/close any prior play on this object first
        self._fired = false

        -- Open with the codec MCI infers from the extension; quote the path for spaces.
        local ok = mci(string.format('open "%s" alias %s', self._path, self._alias))
        if not ok then
            -- One retry forcing the waveaudio device (helps some bare .wav setups).
            ok = mci(string.format('open "%s" type waveaudio alias %s', self._path, self._alias))
        end
        if not ok then
            print("hs.sound: MCI could not open: " .. tostring(self._path))
            return self
        end
        self._open = true

        if self._volume ~= nil then self:volume(self._volume) end
        mci("play " .. self._alias)   -- async

        -- Poll to close the alias when playback ends and to fire the callback.
        self._poll = host.schedule(POLL_MS, function()
            if not self._open then return end
            if not isPlaying(self._alias) then finish(self, "stop") end
        end, POLL_MS)
        return self
    end

    function Sound:stop()
        if not self._open then
            -- Nothing playing; still honour a pending callback so waiters don't hang.
            if self._cb and not self._fired then finish(self, "stop") end
            return self
        end
        mci("stop " .. self._alias)
        finish(self, "stop")
        return self
    end

    function Sound:isPlaying()
        return self._open and isPlaying(self._alias) or false
    end

    -- hs parity no-ops (mudscript sets these but Windows/MCI has no equivalent here).
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
        local self = setmetatable({
            _path   = path,
            _alias  = "msSnd" .. nextId,
            _volume = 1,
            _open   = false,
            _fired  = false,
            _cb     = nil,
            _poll   = nil,
        }, Sound)
        nextId = nextId + 1
        return self
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
