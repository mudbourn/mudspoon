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
-- END --

-- Time helpers --
    function timer.seconds(n) return n           end
    function timer.minutes(n) return n * 60      end
    function timer.hours(n)   return n * 3600    end
    function timer.days(n)    return n * 86400   end
    function timer.weeks(n)   return n * 604800  end

    -- Wall-clock seconds since the epoch (integer resolution; os.time).
    function timer.secondsSinceEpoch()
        return os.time()
    end

    -- Monotonic time in nanoseconds, matching Hammerspoon's absoluteTime shape.
    -- Sourced from the same QPC clock the scheduler uses, so it never jumps.
    function timer.absoluteTime()
        return host.now() * 1e6
    end
-- END --

return timer
