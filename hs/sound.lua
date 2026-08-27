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
int mciGetErrorStringA(unsigned int, char*, unsigned int);
]]
-- END --

-- MCI command helpers --
    local POLL_MS = 100
    -- Ticks to wait for playback to begin before assuming it never will (~1.5s).
    local STARTUP_GRACE = 15
    -- Max re-issues of `play` while a sound can't yet sound: the first play's device
    -- is still settling, OR another alias holds the single MCI wave device (rc=320).
    -- 30 ticks * 100ms = ~3s, enough to outlast the boot chime before the theme chime.
    local REPLAY_MAX = 30
    -- MCIERROR for "all wave devices ... are in use" -- the shared-device collision
    -- between two overlapping plays (e.g. d_Boot still sounding when themeLoaded fires).
    -- Retryable: the device frees the moment the earlier alias closes.
    local MCI_DEVICE_BUSY = 320
    -- Process-wide: has ANY sound been observed actually playing yet? Once true the
    -- audio device is proven warm, so the first-play retry loop is no longer needed.
    local deviceHasPlayed = false

    -- Send one MCI command string. Returns (ok, replyString). ok = MCIERROR 0.
    local function mci(cmd)
        if not WM then return false, "" end
        local buf = ffi.new("char[?]", 256)
        local rc  = WM.mciSendStringA(ffi.cast("LPCSTR", cmd), buf, 256, nil)
        return rc == 0, ffi.string(buf)
    end

    -- Send a command and return the raw MCIERROR code + its decoded human string.
    -- Diagnostic: an empty reply on failure tells us nothing; the error string
    -- distinguishes "device busy/unavailable" from "cannot find file"/bad path.
    local function mciDiag(cmd)
        if not WM then return -1, "no winmm" end
        local buf = ffi.new("char[?]", 256)
        local rc  = WM.mciSendStringA(ffi.cast("LPCSTR", cmd), buf, 256, nil)
        local errbuf = ffi.new("char[?]", 256)
        WM.mciGetErrorStringA(rc, errbuf, 256)
        return tonumber(rc), ffi.string(errbuf)
    end

    -- Is the alias still sounding? `status <alias> mode` -> "playing"/"stopped"/...
    local function isPlaying(alias)
        local ok, mode = mci(string.format("status %s mode", alias))
        return ok and mode == "playing"
    end

    -- Playback position in ms (0 if the alias has not advanced / query fails). Used to
    -- tell a DROPPED play (never advanced -> position 0) from one that already finished
    -- (a short sound -> position > 0) so the self-heal replay can't double an audible.
    local function positionMs(alias)
        local ok, pos = mci(string.format("status %s position", alias))
        if not ok then return 0 end
        return tonumber(pos) or 0
    end

    -- MCI warm-up. The FIRST mciSendString in a process pays subsystem/codec init
    -- (hundreds of ms) synchronously on the timer pump. On mac hs.sound is backed by
    -- GCD and never blocks the timer dispatch; here a cold first-open at the t3 startup
    -- beat stalls the pump, so every later choreography timer fires late in a bunch
    -- ("jumpy" load, theme snapping in against the branding anim). Pay that cost ONCE
    -- at module load, off the choreography path, by opening+closing the waveaudio
    -- device. Cheap, no file, and it primes the driver so the first real :play() is fast.
    local warmed = false
    local function warm()
        if warmed or not WM then return end
        warmed = true
        if mci("open new type waveaudio alias msSndWarm") then
            mci("close msSndWarm")
        end
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
        local orc, oerr = mciDiag(string.format('open "%s" alias %s', self._path, self._alias))
        local ok = (orc == 0)
        if not ok then
            -- One retry forcing the waveaudio device (helps some bare .wav setups).
            orc, oerr = mciDiag(string.format('open "%s" type waveaudio alias %s', self._path, self._alias))
            ok = (orc == 0)
        end
        if not ok then
            print(string.format("hs.sound: MCI could not open (rc=%s %s): %s",
                tostring(orc), tostring(oerr), tostring(self._path)))
            return self
        end
        self._open = true

        if self._volume ~= nil then self:volume(self._volume) end
        local prc, perr = mciDiag("play " .. self._alias)   -- async
        -- rc=320 (device busy) is expected when another sound still holds the wave
        -- device; the poll loop below retries until it frees, so don't log it as an
        -- error. Any OTHER nonzero rc is a genuine failure worth surfacing.
        self._deviceBusy = (prc == MCI_DEVICE_BUSY)
        if prc ~= 0 and not self._deviceBusy then
            print(string.format("hs.sound: MCI could not play (rc=%s %s): %s",
                tostring(prc), tostring(perr), tostring(self._path)))
        end

        -- Poll to close the alias when playback ends and to fire the callback.
        -- CLIPPING GUARD: right after `play`, MCI can briefly report mode ~= "playing"
        -- while the driver opens/buffers the file. Treating that startup window as
        -- "ended" closes the alias before a note sounds -- exactly why themeLoaded went
        -- silent. So we do NOT finish() on a not-playing reading until playback has been
        -- observed actually playing at least once (_started). A bounded grace of
        -- STARTUP_GRACE ticks protects against a sound that never starts (e.g. a codec
        -- that fails post-open) so the alias can't leak forever.
        self._started = false
        self._retries = 0
        local waited = 0
        self._poll = host.schedule(POLL_MS, function()
            if not self._open then return end
            if isPlaying(self._alias) then
                self._started    = true
                deviceHasPlayed  = true          -- device is now proven warm process-wide
                return
            end
            -- not currently "playing":
            if self._started then
                finish(self, "stop")            -- genuinely ended after playing
                return
            end
            -- position > 0 proves audio has advanced even though this tick caught a
            -- non-"playing" blip (buffering, or the gap between `play` landing and the
            -- first "playing" reading -- exactly what happens the instant a busy-retry
            -- finally succeeds). Mark it started so the NEXT stopped tick closes it
            -- cleanly. Without this, a busy-retry that lands after `waited` has already
            -- passed STARTUP_GRACE (waiting out a ~2.2s boot chime) fell straight into
            -- the give-up below and finish()'d the alias mid-note -> silent theme chime.
            if positionMs(self._alias) > 0 then
                self._started    = true
                deviceHasPlayed  = true
                return
            end
            -- position == 0: nothing has sounded yet.
            waited = waited + 1
            -- DROPPED / BUSY self-heal: re-issue `play` while no audio has advanced.
            -- Two cases need this:
            --  (a) the process's first real play, device still cold (deviceHasPlayed
            --      not yet true) -- warm()'s open+close doesn't reliably exercise the
            --      device, and on a fast Windows boot the whole choreography rides
            --      early, so no fixed pre-roll guarantees readiness; or
            --  (b) this alias lost the single MCI wave device to another play (rc=320
            --      busy, e.g. d_Boot still sounding when themeLoaded fires) -- retry
            --      until that earlier alias closes and frees it.
            -- position==0 means a replay can NEVER double an audible. Bounded by REPLAY_MAX.
            if (not deviceHasPlayed or self._deviceBusy) and self._retries < REPLAY_MAX then
                self._retries = self._retries + 1
                local prc = mciDiag("play " .. self._alias)
                self._deviceBusy = (prc == MCI_DEVICE_BUSY)
                return
            end
            if waited >= STARTUP_GRACE then      -- never started, retries done -> give up
                finish(self, "stop")             -- don't leak the alias / device
            end
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
            _open     = false,
            _started  = false,
            _retries  = 0,
            _deviceBusy = false,
            _fired    = false,
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

-- Prime MCI at module load, before any choreography timer exists, so the first
-- real :play() never pays cold-init on the pump. Synchronous by design: the cost is
-- absorbed during app init, not against a startup beat.
warm()

return sound
