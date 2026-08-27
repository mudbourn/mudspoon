-- hs.timer  (Thread A) --
    -- Hammerspoon's timer API over Foundation's scheduler core. Hammerspoon
    -- speaks seconds (floats); Foundation speaks milliseconds. This module is the
    -- only place that conversion lives.
    --
    -- Depends on Foundation only: host.schedule / host.now. It installs no hook
    -- and runs no loop of its own; every timer fires from the one runloop.
-- END --

local host = require("hs.foundation")

local timer = {}

-- Timer object --
    local Timer = {}
    Timer.__index = Timer

    -- Reschedule against Foundation. _interval nil => one-shot.
    local function arm(self, delaySec)
        local delayMs    = delaySec * 1000
        local intervalMs = self._interval and self._interval * 1000 or nil
        self._handle = host.schedule(delayMs, function() self._fn() end, intervalMs)
    end

    function Timer:start()
        if self._handle and self._handle.live then return self end  -- already running
        arm(self, self._delay)
        return self
    end

    function Timer:stop()
        if self._handle then self._handle:cancel() end
        return self
    end

    function Timer:running()
        return self._handle ~= nil and self._handle.live == true
    end

    -- Fire the callback now, out of band. Does not disturb the schedule.
    function Timer:fire()
        local ok, err = pcall(self._fn)
        if not ok then io.stderr:write("mudspoon timer:fire error: " .. tostring(err) .. "\n") end
        return self
    end

    -- Force the next fire to happen `sec` from now, keeping any repeat interval.
    function Timer:setNextTrigger(sec)
        if self._handle then self._handle:cancel() end
        arm(self, sec)
        return self
    end

    function Timer:nextTrigger()
        if not (self._handle and self._handle.live) then return nil end
        return (self._handle.due - host.now()) / 1000
    end
-- END --

-- Constructors --
    -- new(interval, fn): a repeating timer, NOT started. Call :start().
    function timer.new(interval, fn)
        return setmetatable({
            _fn       = fn,
            _delay    = interval,  -- first fire after one interval, like Hammerspoon
            _interval = interval,
            _handle   = nil,
        }, Timer)
    end

    -- doAfter(sec, fn): one-shot, started immediately.
    function timer.doAfter(sec, fn)
        return setmetatable({
            _fn       = fn,
            _delay    = sec,
            _interval = nil,
            _handle   = nil,
        }, Timer):start()
    end

    -- doEvery(interval, fn): repeating, started immediately.
    function timer.doEvery(interval, fn)
        return timer.new(interval, fn):start()
    end

    -- Diagnostic passthrough: live (uncancelled) scheduled-timer count on the pump.
    -- mudscript-only; not part of Hammerspoon's API. Used to detect timer leaks.
    timer._activeCount = host.timerCount
-- END --

-- Time helpers --
    function timer.seconds(n) return n           end
    function timer.minutes(n) return n * 60      end
    function timer.hours(n)   return n * 3600    end
    function timer.days(n)    return n * 86400   end
    function timer.weeks(n)   return n * 604800  end

    -- usleep(us): BLOCKING sleep for `us` MICROSECONDS, matching Hammerspoon. This
    -- is a hard block of the single runloop thread by design -- callers use it for
    -- precise inter-keystroke gaps (ms_core synthetic input), where returning early
    -- or yielding to the pump would reorder events. Sleep() handles the bulk (yields
    -- the CPU, ~1ms granularity); the final <2ms is busy-waited against host.now()
    -- (the same QPC clock the scheduler uses) for the sub-millisecond accuracy that
    -- Sleep alone cannot give. `Sleep` is cdef'd here only -- foundation never declares
    -- it, so there is no duplicate-typedef clash.
    local ffi = require("ffi")
    ffi.cdef("void Sleep(unsigned long);")
    local K = (host.C and host.C.kernel32) or ffi.load("kernel32")
    -- Raise the system timer resolution to 1ms so Sleep() granularity drops from the
    -- ~15.6ms default (which makes usleep(10000) overshoot to ~15ms) to ~1ms. This is
    -- the standard move for input-automation hosts (AHK does the same); the busy-wait
    -- below still trims the sub-ms remainder. Best-effort: pcall so a missing winmm
    -- just leaves the coarser granularity rather than failing the module.
    pcall(function()
        ffi.cdef("unsigned int timeBeginPeriod(unsigned int);")
        ffi.load("winmm").timeBeginPeriod(1)
    end)
    function timer.usleep(us)
        if not us or us <= 0 then return end
        local targetMs = host.now() + us / 1000.0
        local remainMs = targetMs - host.now()
        if remainMs > 2 then K.Sleep(math.floor(remainMs) - 1) end
        while host.now() < targetMs do end  -- spin out the sub-ms remainder
    end

    -- Wall-clock seconds since the epoch, FRACTIONAL -- matching Hammerspoon, whose
    -- secondsSinceEpoch() is gettimeofday-backed (sub-second). os.time() alone is
    -- integer-quantized, which silently breaks every sub-second consumer: hotkey-latch
    -- aging (ms_core _HOTKEY_LATCH_MAX), countdown displays, and worst of all
    -- (now - t0)*1000 "elapsed ms" readouts that would snap to multiples of 1000.
    -- Anchor the integer wall-second captured at load to the monotonic QPC clock and
    -- add the fractional offset since. Absolute value tracks wall time to within the
    -- <1s load-time rounding, but every mac/ call site takes a DELTA of two readings,
    -- where that constant anchor cancels and the sub-ms QPC resolution is exact.
    local _epochAnchor = os.time()
    local _nowAnchor   = host.now()
    function timer.secondsSinceEpoch()
        return _epochAnchor + (host.now() - _nowAnchor) / 1000.0
    end

    -- Monotonic time in nanoseconds, matching Hammerspoon's absoluteTime shape.
    -- Sourced from the same QPC clock the scheduler uses, so it never jumps.
    function timer.absoluteTime()
        return host.now() * 1e6
    end
-- END --

return timer
