-- hs.sound  (Win32 winmm PlaySound backend) --
    -- Hammerspoon's hs.sound plays an NSSound. mudscript uses a narrow slice:
    --   hs.sound.getByFile(path) or hs.sound.getByName(path)  -> sound | nil
    --   sound:play()                                          -- (ms_guardian error cue)
    --
    -- Backed by winmm PlaySoundA. LIMITATION: PlaySound plays WAV only. The paths
    -- mudscript reaches here are .wav (sounds/active/a_Error.wav etc.), so this covers
    -- the live use; a non-WAV file will fail silently (play() returns false). mudscript's
    -- primary audio is its own slot engine -- this hs.sound path is a secondary helper.
    -- A future all-format upgrade is MCI (mciSendString), which decodes via OS codecs.
    --
    -- getByName has no Windows analogue (macOS names system sounds); it returns nil, so
    -- mudscript's `getByFile(p) or getByName(p)` falls through and logs, as intended.
    --
    -- Only one PlaySound can sound at a time (SND_ASYNC); :stop() halts it globally.
    -- CDEF OWNERSHIP: PlaySoundA (winmm) is owned here; base types from foundation.
-- END --

local ffi = require("ffi")
local bit = require("bit")

require("hs.foundation")   -- base ctypes (DWORD, BOOL, LPCSTR, HMODULE)

local okWinmm, WM = pcall(ffi.load, "winmm")
if not okWinmm then WM = nil end

-- Own FFI surface --
    ffi.cdef[[
BOOL PlaySoundA(LPCSTR, HMODULE, DWORD);
]]
-- END --

-- Constants (PlaySound fdwSound flags) --
    local SND_ASYNC    = 0x00000001   -- play asynchronously
    local SND_NODEF    = 0x00000002   -- SND_NODEFAULT: no fallback "ding" if load fails
    local SND_FILENAME = 0x00020000   -- pszSound is a file path
-- END --

-- Small file-exists probe (avoids a hs.fs dependency) --
    local function exists(path)
        local f = io.open(path, "rb")
        if f then f:close(); return true end
        return false
    end

    local function cstr(s)
        s = tostring(s or "")
        local b = ffi.new("char[?]", #s + 1)
        ffi.copy(b, s)
        return b
    end
-- END --

local sound = {}

-- Sound object --
    local Sound = {}
    Sound.__index = Sound

    function Sound:play()
        if not WM then return self end
        local flags = bit.bor(SND_FILENAME, SND_ASYNC, SND_NODEF)
        WM.PlaySoundA(ffi.cast("LPCSTR", cstr(self._path)), nil, flags)
        return self
    end

    -- Global stop: PlaySound(NULL,...) halts whatever is playing (only one at a time).
    function Sound:stop()
        if WM then WM.PlaySoundA(nil, nil, 0) end
        return self
    end

    function Sound:isPlaying() return false end   -- PlaySound exposes no query; best-effort

    -- Accepted for hs parity; PlaySound has no per-sound volume, so this is a no-op store.
    function Sound:volume(v)
        if v == nil then return self._volume end
        self._volume = v
        return self
    end
    function Sound:loopSound(_) return self end
    function Sound:device(_)    return self end
    function Sound:name()       return self._path end
-- END --

-- Constructors --
    local function make(path)
        return setmetatable({ _path = path, _volume = 1 }, Sound)
    end

    function sound.getByFile(path)
        if type(path) ~= "string" or not exists(path) then return nil end
        return make(path)
    end

    -- No Windows system-sound-by-name registry: nil (mudscript's `or` fallback handles it).
    function sound.getByName(_name) return nil end

    function sound.soundTypes() return { "wav" } end
-- END --

return sound
