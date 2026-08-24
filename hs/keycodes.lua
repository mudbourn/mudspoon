-- hs.keycodes  (Thread D, leaf) --
    -- Bidirectional keyname <-> code map, matching Hammerspoon's `hs.keycodes.map`.
    --
    -- CONTRACT #2 (frozen): `map` is bidirectional.
    --   map[name] -> code   (name is a Hammerspoon key name, e.g. "return", "a", "f13")
    --   map[code] -> name    (canonical name for that code)
    --
    -- IMPORTANT divergence from macOS Hammerspoon: the *codes* are Win32
    -- virtual-key codes (VK_*), NOT macOS virtual keycodes. The *names* are kept
    -- identical to Hammerspoon so scripts port unchanged, but the numbers are what
    -- Thread B reports from the low-level hook (KBDLLHOOKSTRUCT.vkCode) and what
    -- Thread C feeds to SendInput. Names are the portable surface; codes are the
    -- Win32 wire value. Do not assume a code equals a macOS keycode.
    --
    -- Leaf: no Foundation dependency, no FFI. Pure static table.
-- END --

local keycodes = {}

-- Forward table: name -> VK code --
    -- One name may share a code with another (aliases). Reverse map below picks a
    -- single canonical name per code from `canonical`.
    local forward = {}

    -- Letters a-z -> VK 0x41-0x5A --
        for i = 0, 25 do
            forward[string.char(97 + i)] = 0x41 + i
        end
    -- END --

    -- Top-row digits 0-9 -> VK 0x30-0x39 --
        for i = 0, 9 do
            forward[tostring(i)] = 0x30 + i
        end
    -- END --

    -- Function keys f1-f24 -> VK 0x70-0x87 --
        -- Hammerspoon exposes f1..f20; Windows has up to f24. We expose all 24.
        for i = 1, 24 do
            forward["f" .. i] = 0x70 + (i - 1)
        end
    -- END --

    -- Numpad digits pad0-pad9 -> VK_NUMPAD0..9 (0x60-0x69) --
        for i = 0, 9 do
            forward["pad" .. i] = 0x60 + i
        end
    -- END --

    -- Numpad operators --
        forward["pad*"]     = 0x6A  -- VK_MULTIPLY
        forward["pad+"]     = 0x6B  -- VK_ADD
        forward["pad-"]     = 0x6D  -- VK_SUBTRACT
        forward["pad."]     = 0x6E  -- VK_DECIMAL
        forward["pad/"]     = 0x6F  -- VK_DIVIDE
        forward["pad="]     = 0x92  -- VK_OEM_NEC_EQUAL (best-effort; rare on PC pads)
        forward["padclear"] = 0x90  -- VK_NUMLOCK  (mac "clear" sits where NumLock is)
        forward["padenter"] = 0x0D  -- VK_RETURN   (numpad Enter shares the code; distinguished only by the extended flag)
    -- END --

    -- Named / editing keys --
        forward["return"]        = 0x0D  -- VK_RETURN
        forward["tab"]           = 0x09  -- VK_TAB
        forward["space"]         = 0x20  -- VK_SPACE
        forward["delete"]        = 0x08  -- VK_BACK   (Hammerspoon "delete" is Backspace)
        forward["forwarddelete"] = 0x2E  -- VK_DELETE
        forward["escape"]        = 0x1B  -- VK_ESCAPE
        forward["help"]          = 0x2D  -- VK_INSERT (mac Help key sits where Insert is on a PC)
        forward["home"]          = 0x24  -- VK_HOME
        forward["end"]           = 0x23  -- VK_END
        forward["pageup"]        = 0x21  -- VK_PRIOR
        forward["pagedown"]      = 0x22  -- VK_NEXT
        forward["left"]          = 0x25  -- VK_LEFT
        forward["up"]            = 0x26  -- VK_UP
        forward["right"]         = 0x27  -- VK_RIGHT
        forward["down"]          = 0x28  -- VK_DOWN
    -- END --

    -- Punctuation, named by the character Hammerspoon uses (OEM VKs) --
        forward[";"]  = 0xBA  -- VK_OEM_1
        forward["="]  = 0xBB  -- VK_OEM_PLUS
        forward[","]  = 0xBC  -- VK_OEM_COMMA
        forward["-"]  = 0xBD  -- VK_OEM_MINUS
        forward["."]  = 0xBE  -- VK_OEM_PERIOD
        forward["/"]  = 0xBF  -- VK_OEM_2
        forward["`"]  = 0xC0  -- VK_OEM_3
        forward["["]  = 0xDB  -- VK_OEM_4
        forward["\\"] = 0xDC  -- VK_OEM_5
        forward["]"]  = 0xDD  -- VK_OEM_6
        forward["'"]  = 0xDE  -- VK_OEM_7
    -- END --

    -- Modifiers and locks --
        -- Hammerspoon's "cmd" is the Windows key here (the closest ergonomic analog).
        -- Left/right variants use the side-specific VKs so hotkey chord matching in
        -- Thread F can tell them apart; the bare name uses the side-specific left VK
        -- (GetAsyncKeyState on the generic VK also reads true, but SendInput wants a
        -- concrete key, so we pin to left).
        forward["cmd"]        = 0x5B  -- VK_LWIN
        forward["rightcmd"]   = 0x5C  -- VK_RWIN
        forward["alt"]        = 0xA4  -- VK_LMENU
        forward["option"]     = 0xA4  -- alias of alt
        forward["rightalt"]   = 0xA5  -- VK_RMENU
        forward["rightoption"]= 0xA5  -- alias of rightalt
        forward["shift"]      = 0xA0  -- VK_LSHIFT
        forward["rightshift"] = 0xA1  -- VK_RSHIFT
        forward["ctrl"]       = 0xA2  -- VK_LCONTROL
        forward["rightctrl"]  = 0xA3  -- VK_RCONTROL
        forward["capslock"]   = 0x14  -- VK_CAPITAL

        -- Windows-friendly aliases that have no Hammerspoon name. Harmless additions
        -- on the forward side; never chosen as a canonical reverse name below.
        forward["insert"]      = 0x2D  -- VK_INSERT
        forward["numlock"]     = 0x90  -- VK_NUMLOCK
        forward["scrolllock"]  = 0x91  -- VK_SCROLL
        forward["pause"]       = 0x13  -- VK_PAUSE
        forward["printscreen"] = 0x2C  -- VK_SNAPSHOT

        -- "fn" has no Win32 virtual-key code (handled below the OS on most laptops),
        -- so it is intentionally absent. hotkey/eventtap must not rely on it here.
    -- END --
-- END --

-- Canonical names for the reverse map --
    -- When several names share a code, the reverse map[code] resolves to the name
    -- Hammerspoon scripts expect. Anything not listed here contributes its forward
    -- name to the reverse map only if no canonical claims that code first.
    local canonical = {
        [0x0D] = "return",   -- not "padenter"
        [0xA4] = "alt",      -- not "option"
        [0xA5] = "rightalt", -- not "rightoption"
        [0x2D] = "help",     -- not "insert"
        [0x90] = "padclear", -- not "numlock"
    }
-- END --

-- Build the bidirectional map --
    local map = {}

    -- Names first (forward direction). --
        for name, code in pairs(forward) do
            map[name] = code
        end
    -- END --

    -- Codes second (reverse direction), canonical winning ties. --
        -- Seed canonical picks so an arbitrary pairs() order can't overwrite them.
        for code, name in pairs(canonical) do
            map[code] = name
        end

        for name, code in pairs(forward) do
            if map[code] == nil then
                map[code] = name
            end
        end
    -- END --

    keycodes.map = map
-- END --

-- Compatibility stubs --
    -- Thread D owns only the static table. These exist so `require`rs that probe the
    -- fuller Hammerspoon surface don't nil-crash. Layout switching is a no-op on the
    -- single fixed layout the host assumes today; revisit if per-layout remapping lands.
    function keycodes.currentLayout()
        return "US"
    end

    function keycodes.currentSourceID()
        return "com.mudspoon.keylayout.US"
    end

    -- Hammerspoon's hs.keycodes.map is also callable-ish in some code via these
    -- helpers; provide the direct lookups against our frozen table.
    function keycodes.keyCodeForName(name)
        return map[name]
    end

    function keycodes.nameForKeyCode(code)
        return map[code]
    end
-- END --

return keycodes
