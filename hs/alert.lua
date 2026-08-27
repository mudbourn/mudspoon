-- hs.alert  (alert policy layer, pure Lua) --
    -- Hammerspoon's `hs.alert` over the native window primitive. This module holds
    -- no FFI and cdefs nothing: it decides *what* to show and *where*, and drives
    -- the fade off the one runloop through hs.timer. All pixel-pushing (create,
    -- alpha, destroy) lives behind the frozen `window` contract.
    --
    -- Depends on:
    --   * hs.alert.window  -- the native window primitive (the other half of this
    --                          packet). Frozen contract:
    --                            window.show(text, { x, y, w, h, alpha, bg, fg }) -> handle
    --                            handle:setAlpha(byte)   -- 0..255
    --                            handle:close()          -- idempotent
    --   * hs.timer         -- fade animation + hold, off the shared runloop
    --   * hs.screen        -- screen geometry for centering
    --
    -- No hook, no message loop, no timer of its own beyond hs.timer. Every frame of
    -- every fade advances from foundation's one runloop.
-- END --

local window = require("hs.alert.window")
local timer  = require("hs.timer")
local screen = require("hs.screen")

local alert = {}

-- Default style (Hammerspoon parity, translated to the window contract) --
    -- Hammerspoon exposes far more keys; we honour the ones that map onto the
    -- window primitive (text, geometry, bg/fg) and the animation. Colours are the
    -- COLORREF integers the native side draws with (0x00BBGGRR), matching the
    -- proven spike palette; a caller may pass style.fillColor/.textColor (or the
    -- literal .bg/.fg) to override.
    alert.defaultStyle = {
        textSize        = 20,     -- point size the native side renders at
        fillColor       = 0x001C1F24,  -- window background (deepslate)
        textColor       = 0x00E8E8E8,  -- text foreground (near-white)
        padding         = 16,     -- inner margin, px, around the text block
        lineSpacing     = 6,      -- extra px between wrapped/newline lines
        fadeInDuration  = 0.15,   -- seconds; 0 = appear instantly
        fadeOutDuration = 0.15,   -- seconds; 0 = vanish instantly
        atScreenEdge    = 0,      -- 0 centered, 1 top, 2 bottom (Hammerspoon-ish)
    }

    -- Approximate glyph advance as a fraction of the point size. The native side
    -- owns the real font metrics; this is only for sizing the window rect before
    -- it exists, so a generous estimate that never clips is the safe bias.
    local CHAR_W_RATIO = 0.62
    local LINE_H_RATIO = 1.35

    -- Animation cadence: one alpha step every FRAME_MS, like the spike's fade.
    local FRAME_MS = 30

    -- Gap between stacked alerts, px.
    local STACK_GAP = 12
-- END --

-- Style resolution --
    -- Merge a caller style over the defaults. `bg`/`fg` win over fillColor/textColor
    -- so a caller can speak either vocabulary.
    local function resolveStyle(style)
        local s = {}
        for k, v in pairs(alert.defaultStyle) do s[k] = v end
        if type(style) == "table" then
            for k, v in pairs(style) do s[k] = v end
        end
        s.bg = s.bg or s.fillColor
        s.fg = s.fg or s.textColor
        return s
    end
-- END --

-- Text measurement -> window rect --
    -- Split on newlines, size the box to the widest line and the line count. This
    -- is deliberately an over-estimate (see CHAR_W_RATIO): the native draw is
    -- top-left anchored inside the rect, so a rect a few px too wide is invisible,
    -- a rect too narrow clips.
    local function measure(text, s)
        local longest, lines = 0, 0
        for line in (text .. "\n"):gmatch("(.-)\n") do
            lines = lines + 1
            if #line > longest then longest = #line end
        end
        if lines == 0 then lines = 1 end

        local charW  = s.textSize * CHAR_W_RATIO
        local lineH  = s.textSize * LINE_H_RATIO
        local w = math.ceil(longest * charW) + s.padding * 2
        local h = math.ceil(lines * lineH + (lines - 1) * s.lineSpacing) + s.padding * 2
        return w, h
    end
-- END --

-- Active-alert registry + stacking --
    -- Insertion-ordered list of live alerts. Each entry:
    --   { id, handle, h, y, alpha, closing }
    -- The window contract has no move primitive, so a rect is fixed at creation:
    -- we stack a new alert *below* the current lowest live one and tolerate the gap
    -- a middle alert leaves when it closes (it re-fills as the stack drains).
    local active = {}   -- array, oldest first
    local byId   = {}   -- id -> entry
    local nextId = 0

    local function newId()
        nextId = nextId + 1
        return "mudspoon-alert-" .. nextId
    end

    -- Where the top of the next alert of height `h` should sit on `scr`.
    local function stackTop(scr, s, h)
        -- Lowest occupied edge across live alerts, or nil if the stack is empty.
        local lowest
        for _, e in ipairs(active) do
            local edge = e.y + e.h
            if not lowest or edge > lowest then lowest = edge end
        end

        if lowest then
            return lowest + STACK_GAP
        end

        -- First alert: honour atScreenEdge, default centred.
        if s.atScreenEdge == 1 then
            return scr.y + s.padding
        elseif s.atScreenEdge == 2 then
            return scr.y + scr.h - h - s.padding
        end
        return scr.y + math.floor((scr.h - h) / 2)
    end

    local function remove(entry)
        byId[entry.id] = nil
        for i = #active, 1, -1 do
            if active[i] == entry then table.remove(active, i) break end
        end
    end
-- END --

-- Fade animation (off the runloop, via hs.timer) --
    -- Ramp `entry` from its current alpha toward `target` over `seconds`, then call
    -- `done`. A step every FRAME_MS; a zero (or negative) duration snaps instantly.
    --
    -- Starting a ramp supersedes any ramp already animating this entry: each entry
    -- carries a generation counter, and a step abandons itself the moment a newer
    -- ramp has bumped it. Without this, a fade-out beginning mid-fade-in would leave
    -- two chains driving the same alpha in opposite directions, and it would never
    -- settle (they oscillate around each other).
    local function ramp(entry, target, seconds, done)
        entry.rampGen = (entry.rampGen or 0) + 1
        local myGen   = entry.rampGen

        local totalMs = (seconds or 0) * 1000
        if totalMs <= 0 then
            entry.alpha = target
            if entry.handle then entry.handle:setAlpha(target) end
            if done then done() end
            return
        end

        local delta = (target - entry.alpha) * (FRAME_MS / totalMs)

        local function step()
            if not entry.handle then return end       -- already destroyed
            if entry.rampGen ~= myGen then return end  -- a newer ramp took over
            entry.alpha = entry.alpha + delta

            local reached = (delta >= 0 and entry.alpha >= target)
                         or (delta <  0 and entry.alpha <= target)
            if reached then
                entry.alpha = target
                entry.handle:setAlpha(target)
                if done then done() end
                return
            end

            entry.handle:setAlpha(math.floor(entry.alpha + 0.5))
            timer.doAfter(FRAME_MS / 1000, step)
        end

        step()
    end

    -- Fade `entry` out and destroy it. Idempotent: guarded by entry.closing so a
    -- duration-elapsed close and a manual closeAll can't double-fade.
    local function fadeAndClose(entry, seconds)
        if entry.closing then return end
        entry.closing = true
        ramp(entry, 0, seconds, function()
            if entry.handle then entry.handle:close() end
            entry.handle = nil
            remove(entry)
        end)
    end
-- END --

-- Public API --
    -- hs.alert.show(text, [style], [duration])
    --   Hammerspoon also accepts show(text, seconds); we detect a numeric second
    --   argument and treat it as the duration. Default duration is 2s, centred.
    --   Returns an id usable with closeSpecific().
    function alert.show(text, style, duration)
        if type(style) == "number" then
            style, duration = nil, style
        end
        duration = duration or 2

        text = tostring(text)
        local s   = resolveStyle(style)
        local scr = (screen.mainScreen and screen.mainScreen() or screen.primaryScreen()):frame()

        local w, h = measure(text, s)
        w = math.min(w, scr.w - s.padding * 2)  -- never wider than the screen
        local x = scr.x + math.floor((scr.w - w) / 2)
        local y = stackTop(scr, s, h)

        local fadeIn = s.fadeInDuration or 0
        local startAlpha = fadeIn > 0 and 0 or 255

        local handle = window.show(text, {
            x = x, y = y, w = w, h = h,
            alpha = startAlpha,
            bg = s.bg, fg = s.fg,
        })

        local entry = {
            id      = newId(),
            handle  = handle,
            h       = h,
            y       = y,
            alpha   = startAlpha,
            closing = false,
        }
        active[#active + 1] = entry
        byId[entry.id] = entry

        if fadeIn > 0 then
            ramp(entry, 255, fadeIn)
        end

        -- Hold, then fade out. A non-positive duration means "until closed".
        if duration and duration > 0 then
            timer.doAfter(duration, function()
                fadeAndClose(entry, s.fadeOutDuration)
            end)
        end

        entry.fadeOut = s.fadeOutDuration  -- remembered for closeAll/closeSpecific
        return entry.id
    end

    -- hs.alert.closeSpecific(id, [seconds]) -- fade one alert out early.
    -- seconds defaults to the alert's own fade-out duration.
    function alert.closeSpecific(id, seconds)
        local entry = byId[id]
        if not entry then return end
        fadeAndClose(entry, seconds or entry.fadeOut or 0)
    end

    -- hs.alert.closeAll([seconds]) -- fade every live alert out.
    -- seconds overrides each alert's own fade-out duration when given.
    function alert.closeAll(seconds)
        -- Snapshot: fadeAndClose mutates `active` as fades complete.
        local snapshot = {}
        for i = 1, #active do snapshot[i] = active[i] end
        for _, entry in ipairs(snapshot) do
            fadeAndClose(entry, seconds or entry.fadeOut or 0)
        end
    end
-- END --

return alert
