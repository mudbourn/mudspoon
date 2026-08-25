-- hs.eventtap.event  (Thread C, post side) --
    -- Constructs synthetic events and injects them with SendInput, matching
    -- Hammerspoon's `hs.eventtap.event`. This is the POST half of the event
    -- contract; the READ half lives in foundation (host.newEvent + getters) and
    -- in hs.eventtap (Thread B).
    --
    -- Depends on FOUNDATION (`hs.foundation`) for the shared event object and the
    -- loaded user32, and on Thread D (`hs.keycodes`, contract 2) to turn key names
    -- into virtual-key codes. Softly on Thread G (`hs.screen`) for absolute mouse
    -- moves only -- absent G, mouse events act at the current cursor position.
    --
    -- CONTRACT (post side): this module attaches :post() to the SHARED prototype
    -- (host.eventProto). Requiring it upgrades every event object -- including ones
    -- the read side already built -- so :post() works everywhere. Every INPUT we
    -- send stamps host.INJECTED_MAGIC into dwExtraInfo; the read side reads it back
    -- as ev:getProperty("extra"), so a tap can ignore its own injected events.
    --
    -- Owns: SendInput and the INPUT family of structs. cdefs no shared type.
-- END --

local ffi = require("ffi")

local host     = require("hs.foundation")
local keycodes = require("hs.keycodes")
local U        = (host.C and host.C.user32) or ffi.load("user32")

-- Soft dependency on hs.screen (Thread G), for absolute mouse moves only. --
    local screen
    do
        local ok, mod = pcall(require, "hs.screen")
        if ok then
            screen = mod
        elseif not tostring(mod):match("module '.-' not found") then
            error(mod)
        end
    end
-- END --

-- Own FFI surface (functions + unique structs; scalars come from foundation) --
    ffi.cdef[[
typedef struct { LONG dx; LONG dy; DWORD mouseData; DWORD dwFlags; DWORD time; ULONG_PTR dwExtraInfo; } MOUSEINPUT;
typedef struct { WORD wVk; WORD wScan; DWORD dwFlags; DWORD time; ULONG_PTR dwExtraInfo; } KEYBDINPUT;
typedef struct { DWORD uMsg; WORD wParamL; WORD wParamH; } HARDWAREINPUT;
typedef struct {
    DWORD type;
    union { MOUSEINPUT mi; KEYBDINPUT ki; HARDWAREINPUT hi; } u;
} INPUT;

UINT SendInput(UINT, INPUT*, int);
]]
-- END --

-- Constants --
    local INPUT_MOUSE    = 0
    local INPUT_KEYBOARD = 1

    local KEYEVENTF_KEYUP       = 0x0002
    local KEYEVENTF_EXTENDEDKEY = 0x0001

    local MOUSEEVENTF_MOVE       = 0x0001
    local MOUSEEVENTF_LEFTDOWN   = 0x0002
    local MOUSEEVENTF_LEFTUP     = 0x0004
    local MOUSEEVENTF_RIGHTDOWN  = 0x0008
    local MOUSEEVENTF_RIGHTUP    = 0x0010
    local MOUSEEVENTF_MIDDLEDOWN = 0x0020
    local MOUSEEVENTF_MIDDLEUP   = 0x0040
    local MOUSEEVENTF_WHEEL      = 0x0800
    local MOUSEEVENTF_HWHEEL     = 0x1000
    local MOUSEEVENTF_ABSOLUTE   = 0x8000
    local MOUSEEVENTF_VIRTUALDESK= 0x4000

    local WHEEL_DELTA = 120

    local MAGIC = host.INJECTED_MAGIC

    -- Modifier flag -> virtual-key code used when physically pressing it.
    local MOD_VK = {
        ctrl  = 0x11,  -- VK_CONTROL
        alt   = 0x12,  -- VK_MENU
        shift = 0x10,  -- VK_SHIFT
        cmd   = 0x5B,  -- VK_LWIN (cmd aliases the Windows key)
    }
    -- Stable press order (and reverse for release) so chords are well-formed.
    local MOD_ORDER = { "ctrl", "alt", "shift", "cmd" }

    -- Keys that must carry KEYEVENTF_EXTENDEDKEY to be interpreted correctly.
    local EXTENDED = {
        [0x21]=true,[0x22]=true,[0x23]=true,[0x24]=true,        -- pgup pgdn end home
        [0x25]=true,[0x26]=true,[0x27]=true,[0x28]=true,        -- arrows
        [0x2D]=true,[0x2E]=true,                                -- insert delete
        [0x5B]=true,[0x5C]=true,[0x5D]=true,                    -- lwin rwin apps
        [0x6F]=true,[0x90]=true,                                -- numpad divide, numlock
        [0xA3]=true,[0xA5]=true,                                -- right ctrl, right alt
    }
-- END --

-- Flags helpers --
    -- Accept mods as an array {"cmd","shift"} or a set-table {cmd=true}; normalise
    -- to a set-table of truthy modifier keys.
    local function toFlagSet(mods)
        local set = {}
        if not mods then return set end
        -- array form
        for _, m in ipairs(mods) do
            m = tostring(m):lower()
            if m == "option" then m = "alt" end
            if m == "control" then m = "ctrl" end
            set[m] = true
        end
        -- set-table form (any non-integer truthy key)
        for k, v in pairs(mods) do
            if type(k) == "string" and v then
                local m = k:lower()
                if m == "option" then m = "alt" end
                if m == "control" then m = "ctrl" end
                set[m] = true
            end
        end
        return set
    end
-- END --

-- INPUT builders --
    -- Fill a keyboard INPUT slot in place. `extra` is the dwExtraInfo signature to
    -- stamp -- MAGIC by default, or a caller-set eventSourceUserData (see :post()),
    -- so a consumer's own sentinel round-trips back through the read hook.
    local function fillKey(slot, vk, up, extra)
        slot.type = INPUT_KEYBOARD
        local ki = slot.u.ki
        ki.wVk         = vk
        ki.wScan       = 0
        ki.dwFlags     = (up and KEYEVENTF_KEYUP or 0)
                       + (EXTENDED[vk] and KEYEVENTF_EXTENDEDKEY or 0)
        ki.time        = 0
        ki.dwExtraInfo = extra or MAGIC
    end

    -- Fill a mouse INPUT slot in place. dx/dy meaningful only with MOVE/ABSOLUTE.
    local function fillMouse(slot, flags, data, dx, dy, extra)
        slot.type = INPUT_MOUSE
        local mi = slot.u.mi
        mi.dx          = dx or 0
        mi.dy          = dy or 0
        mi.mouseData   = data or 0
        mi.dwFlags     = flags
        mi.time        = 0
        mi.dwExtraInfo = extra or MAGIC
    end

    -- Materialise a sequence of fill-closures into one INPUT[n] and send it atomically.
    local function send(fills)
        local n = #fills
        if n == 0 then return end
        local arr = ffi.new("INPUT[?]", n)
        for i = 1, n do fills[i](arr[i - 1]) end
        U.SendInput(n, arr, ffi.sizeof("INPUT"))
    end
-- END --

-- Absolute-move normalisation (soft G dependency) --
    -- Convert a virtual-desktop pixel point to the 0..65535 range SendInput wants
    -- with MOUSEEVENTF_VIRTUALDESK. Returns nil if hs.screen is unavailable, so the
    -- caller can fall back to acting at the current cursor position.
    local function normAbsolute(x, y)
        if not screen then return nil end

        local minx, miny = math.huge, math.huge
        local maxx, maxy = -math.huge, -math.huge
        for _, s in ipairs(screen.allScreens()) do
            local f = s:fullFrame()
            if f.x < minx then minx = f.x end
            if f.y < miny then miny = f.y end
            if f.x + f.w > maxx then maxx = f.x + f.w end
            if f.y + f.h > maxy then maxy = f.y + f.h end
        end

        local vw = math.max(maxx - minx, 1)
        local vh = math.max(maxy - miny, 1)
        local nx = math.floor((x - minx) * 65535 / vw + 0.5)
        local ny = math.floor((y - miny) * 65535 / vh + 0.5)
        return nx, ny
    end
-- END --

-- The mouse button/type table --
    -- Maps our event-type strings to the SendInput down/up flags.
    local MOUSE_FLAGS = {
        leftMouseDown  = MOUSEEVENTF_LEFTDOWN,   leftMouseUp  = MOUSEEVENTF_LEFTUP,
        rightMouseDown = MOUSEEVENTF_RIGHTDOWN,  rightMouseUp = MOUSEEVENTF_RIGHTUP,
        otherMouseDown = MOUSEEVENTF_MIDDLEDOWN, otherMouseUp = MOUSEEVENTF_MIDDLEUP,
    }
-- END --

-- :post() -- the contract's post side, attached to the SHARED prototype --
    -- Injects self through SendInput. Dispatches on the event type category.
    local function post(self)
        local t     = self._type
        local props = self._props or {}
        local flags = self._flags or {}
        local fills = {}

        -- dwExtraInfo signature to stamp on every INPUT of this event. A consumer
        -- can override it via setProperty(eventSourceUserData, n) -- stored as
        -- props.extra -- to tag its own events with a sentinel the read hook echoes
        -- back as getProperty(eventSourceUserData). Absent one, foundation's MAGIC.
        local extra = props.extra or MAGIC

        -- Optional absolute move before a mouse action, when the event carries a
        -- target point and hs.screen is present to normalise it.
        local function maybeMove()
            if props.x == nil then return end
            local nx, ny = normAbsolute(props.x, props.y)
            if nx then
                fills[#fills + 1] = function(s)
                    fillMouse(s, MOUSEEVENTF_MOVE + MOUSEEVENTF_ABSOLUTE + MOUSEEVENTF_VIRTUALDESK, 0, nx, ny, extra)
                end
            end
        end

        if t == "keyDown" or t == "keyUp" then
            local vk = self._keyCode
            if not vk then error("keyboard event has no keyCode", 2) end
            local up = (t == "keyUp")

            if not up then
                -- press modifiers, then the key
                for _, m in ipairs(MOD_ORDER) do
                    if flags[m] then fills[#fills + 1] = function(s) fillKey(s, MOD_VK[m], false, extra) end end
                end
                fills[#fills + 1] = function(s) fillKey(s, vk, false, extra) end
            else
                -- release the key, then the modifiers (reverse order)
                fills[#fills + 1] = function(s) fillKey(s, vk, true, extra) end
                for i = #MOD_ORDER, 1, -1 do
                    local m = MOD_ORDER[i]
                    if flags[m] then fills[#fills + 1] = function(s) fillKey(s, MOD_VK[m], true, extra) end end
                end
            end

        elseif MOUSE_FLAGS[t] then
            maybeMove()
            local f = MOUSE_FLAGS[t]
            fills[#fills + 1] = function(s) fillMouse(s, f, 0, nil, nil, extra) end

        elseif t == "mouseMoved" then
            maybeMove()

        elseif t == "scrollWheel" then
            -- props.scrollY / scrollX in wheel notches (1 notch = WHEEL_DELTA).
            local sy = props.scrollY or 0
            local sx = props.scrollX or 0
            if sy ~= 0 then
                fills[#fills + 1] = function(s) fillMouse(s, MOUSEEVENTF_WHEEL,  sy * WHEEL_DELTA, nil, nil, extra) end
            end
            if sx ~= 0 then
                fills[#fills + 1] = function(s) fillMouse(s, MOUSEEVENTF_HWHEEL, sx * WHEEL_DELTA, nil, nil, extra) end
            end

        else
            error("cannot post event of type '" .. tostring(t) .. "'", 2)
        end

        send(fills)
        return self  -- Hammerspoon returns the event for chaining
    end

    -- Attach to the shared prototype: upgrades every event object, present and future.
    host.eventProto.post = post
-- END --

-- :setProperty() -- the write complement of foundation's :getProperty() --
    -- Foundation gives events a read-only getProperty(k); consumers that build and
    -- post synthetic events also need to WRITE fields (a button number, a scroll
    -- delta, an eventSourceUserData sentinel). We attach the setter here rather than
    -- in frozen foundation, on the same shared prototype as :post(). The key is one
    -- of hs.eventtap.event.properties below; the value is stored verbatim in _props,
    -- which getProperty reads and post() consumes. Returns self for chaining.
    host.eventProto.setProperty = function(self, k, v)
        self._props[k] = v
        return self
    end
-- END --

local event = {}

-- event.types -- string constants matching what getType() returns --
    -- Real Hammerspoon uses integer CGEventType values; here they are the strings the
    -- foundation event object carries, so `event.types.keyDown == ev:getType()` holds.
    event.types = {
        keyDown        = "keyDown",        keyUp         = "keyUp",
        leftMouseDown  = "leftMouseDown",  leftMouseUp   = "leftMouseUp",
        rightMouseDown = "rightMouseDown", rightMouseUp  = "rightMouseUp",
        otherMouseDown = "otherMouseDown", otherMouseUp  = "otherMouseUp",
        mouseMoved     = "mouseMoved",     scrollWheel   = "scrollWheel",

        -- Constants the consumer references but which foundation's read hook does
        -- NOT yet EMIT: flagsChanged (modifier press/release) and the drag types
        -- (mouseMoved while a button is held). Defined so `event.types.flagsChanged`
        -- resolves and comparisons don't silently test against nil -- but a tap on
        -- these will not fire until foundation emits them (a separate, larger change
        -- in the key/mouse hooks: flagsChanged needs modifier-transition tracking;
        -- *Dragged needs button-state tracking on WM_MOUSEMOVE). See TODO note.
        flagsChanged       = "flagsChanged",
        leftMouseDragged   = "leftMouseDragged",
        rightMouseDragged  = "rightMouseDragged",
        otherMouseDragged  = "otherMouseDragged",
    }
-- END --

-- event.properties -- opaque keys for get/setProperty (contract: stable keys) --
    -- Real Hammerspoon uses integer CGEventField values; here (as with event.types)
    -- they are the string keys the foundation event object stores fields under, so a
    -- value written with setProperty is read back verbatim by getProperty, and the
    -- ones the read hook already populates line up:
    --   * eventSourceUserData -> "extra": foundation reads dwExtraInfo into
    --     _props.extra, and post() stamps _props.extra into dwExtraInfo. So a
    --     consumer's setProperty(eventSourceUserData, 999) round-trips through
    --     inject -> hook, the idiom for tagging/recognising one's own events.
    --   * mouseEventButtonNumber -> "buttonNumber": populated on real mouse events.
    --   * scrollWheelEventDeltaAxis1 -> "mouseData": the wheel delta on real scrolls.
    -- The rest (autorepeat, per-axis deltas, axis2) are not populated by the read
    -- hook today, so on a REAL event they read nil (treated as 0/absent); they are
    -- still settable on synthetic events a consumer builds and posts.
    event.properties = {
        eventSourceUserData        = "extra",
        mouseEventButtonNumber     = "buttonNumber",
        scrollWheelEventDeltaAxis1 = "mouseData",
        scrollWheelEventDeltaAxis2 = "mouseDataAxis2",
        keyboardEventAutorepeat    = "autorepeat",
        mouseEventDeltaX           = "deltaX",
        mouseEventDeltaY           = "deltaY",
    }
-- END --

-- Constructors --
    -- hs.eventtap.event.newKeyEvent([mods], key, isDown)
    --   mods : array or set-table of modifiers (optional; omit for a bare key)
    --   key  : Hammerspoon key name (string) or a raw virtual-key code (number)
    --   isDown: true = keyDown, false = keyUp
    function event.newKeyEvent(mods, key, isDown)
        -- 2-arg form newKeyEvent(key, isDown): shift the args.
        if type(mods) == "string" or type(mods) == "number" then
            mods, key, isDown = nil, mods, key
        end

        local code = (type(key) == "number") and key or keycodes.keyCodeForName(key)
        if not code then error("unknown key: " .. tostring(key), 2) end

        return host.newEvent{
            type    = isDown and "keyDown" or "keyUp",
            keyCode = code,
            flags   = toFlagSet(mods),
        }
    end

    -- hs.eventtap.event.newMouseEvent(type, point, [mods])
    function event.newMouseEvent(t, point, mods)
        point = point or {}
        return host.newEvent{
            type  = t,
            flags = toFlagSet(mods),
            props = { x = point.x or point[1], y = point.y or point[2] },
        }
    end

    -- hs.eventtap.event.newScrollEvent(offsets, [mods], [unit])
    --   offsets : {horizontal, vertical} in wheel notches (unit is advisory here;
    --             Windows scrolls in WHEEL_DELTA notches regardless).
    function event.newScrollEvent(offsets, mods, _unit)
        offsets = offsets or {}
        return host.newEvent{
            type  = "scrollWheel",
            flags = toFlagSet(mods),
            props = { scrollX = offsets[1] or 0, scrollY = offsets[2] or 0 },
        }
    end
-- END --

-- Test seam: pure helpers, usable without FFI/Win32. --
    event._toFlagSet    = toFlagSet
    event._normAbsolute = normAbsolute
-- END --

return event
