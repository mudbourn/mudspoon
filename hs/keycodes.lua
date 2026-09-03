-- hs.keycodes  (Thread D, leaf) --
    -- Bidirectional keyname <-> code map, matching Hammerspoon's `hs.keycodes.map`.
    --
    -- CONTRACT #2 (frozen): `map` is bidirectional.
    --   map[name] -> code   (name is a Hammerspoon key name, e.g. "return", "a", "f13")
    --   map[code] -> name    (canonical name for that code)
    --
    -- The codes ARE macOS virtual keycodes, exactly as Hammerspoon reports them, so a
    -- script that hardcodes mac keycodes (arrow 123, shift 56, ...) resolves the same
    -- key it does on macOS. The Win32 virtual-key codes the low-level hook reports and
    -- SendInput consumes are a separate wire value; macToVk / vkToMac translate at that
    -- OS boundary (Thread B on read, Thread C on write). Names are the portable surface.
    --
    -- Leaf: no Foundation dependency, no FFI. Pure static table.
-- END --

local keycodes = {}

-- Build tables from one master definition --
    -- forward: name -> mac keycode. MAC_TO_VK / VK_TO_MAC: the OS-boundary translation.
    -- First definition of a code wins the reverse direction, so primary names and the
    -- canonical VK owner are declared before their aliases.
    local forward   = {}
    local MAC_TO_VK = {}
    local VK_TO_MAC = {}

    local function def(name, mac, vk)
        forward[name] = mac
        if MAC_TO_VK[mac] == nil then MAC_TO_VK[mac] = vk end
        if VK_TO_MAC[vk] == nil then VK_TO_MAC[vk] = mac end
    end

    -- Letters a-z (mac codes are not sequential) --
        local LETTER_MAC = { 0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6 }
        for i = 0, 25 do
            def(string.char(97 + i), LETTER_MAC[i + 1], 0x41 + i)
        end
    -- END --

    -- Top-row digits 0-9 --
        local DIGIT_MAC = { [0] = 29, [1] = 18, [2] = 19, [3] = 20, [4] = 21, [5] = 23, [6] = 22, [7] = 26, [8] = 28, [9] = 25 }
        for i = 0, 9 do
            def(tostring(i), DIGIT_MAC[i], 0x30 + i)
        end
    -- END --

    -- Function keys f1-f20 --
        local FKEY_MAC = { 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90 }
        for i = 1, 20 do
            def("f" .. i, FKEY_MAC[i], 0x70 + (i - 1))
        end
    -- END --

    -- Numpad digits pad0-pad9 --
        local PAD_MAC = { [0] = 82, [1] = 83, [2] = 84, [3] = 85, [4] = 86, [5] = 87, [6] = 88, [7] = 89, [8] = 91, [9] = 92 }
        for i = 0, 9 do
            def("pad" .. i, PAD_MAC[i], 0x60 + i)
        end
    -- END --

    -- Numpad operators --
        def("pad*", 67, 0x6A)
        def("pad+", 69, 0x6B)
        def("pad-", 78, 0x6D)
        def("pad.", 65, 0x6E)
        def("pad/", 75, 0x6F)
        def("pad=", 81, 0x92)
        def("padclear", 71, 0x90)
        def("padenter", 76, 0x0D)
    -- END --

    -- Named / editing keys (return owns VK 0x0D over padenter, forced below) --
        def("return", 36, 0x0D)
        def("tab", 48, 0x09)
        def("space", 49, 0x20)
        def("delete", 51, 0x08)
        def("forwarddelete", 117, 0x2E)
        def("escape", 53, 0x1B)
        def("help", 114, 0x2D)
        def("home", 115, 0x24)
        def("end", 119, 0x23)
        def("pageup", 116, 0x21)
        def("pagedown", 121, 0x22)
        def("left", 123, 0x25)
        def("up", 126, 0x26)
        def("right", 124, 0x27)
        def("down", 125, 0x28)
    -- END --

    -- Punctuation, named by the character Hammerspoon uses --
        def(";", 41, 0xBA)
        def("=", 24, 0xBB)
        def(",", 43, 0xBC)
        def("-", 27, 0xBD)
        def(".", 47, 0xBE)
        def("/", 44, 0xBF)
        def("`", 50, 0xC0)
        def("[", 33, 0xDB)
        def("\\", 42, 0xDC)
        def("]", 30, 0xDD)
        def("'", 39, 0xDE)
    -- END --

    -- Modifiers and locks (cmd aliases the Windows key; sides use the specific VKs) --
        def("cmd", 55, 0x5B)
        def("rightcmd", 54, 0x5C)
        def("alt", 58, 0xA4)
        def("option", 58, 0xA4)
        def("rightalt", 61, 0xA5)
        def("rightoption", 61, 0xA5)
        def("shift", 56, 0xA0)
        def("rightshift", 60, 0xA1)
        def("ctrl", 59, 0xA2)
        def("rightctrl", 62, 0xA3)
        def("capslock", 57, 0x14)
    -- END --

    -- Windows-side aliases sharing a physical key with a mac name above --
        def("insert", 114, 0x2D)
        def("numlock", 71, 0x90)
    -- END --

    -- Reverse-direction overrides at the OS boundary --
        -- VK_RETURN is the numpad Enter and the main Return; the main key wins. The
        -- generic modifier VKs (the hook can deliver these instead of the sided ones)
        -- resolve to the left-side mac code.
        VK_TO_MAC[0x0D] = 36
        VK_TO_MAC[0x10] = 56
        VK_TO_MAC[0x11] = 59
        VK_TO_MAC[0x12] = 58
    -- END --
-- END --

-- Canonical names for the reverse map --
    -- When several names share a mac code, map[code] resolves to the name Hammerspoon
    -- scripts expect. Anything unlisted contributes its own name if no canonical claims
    -- the code first.
    local canonical = {
        [58]  = "alt",
        [61]  = "rightalt",
        [114] = "help",
        [71]  = "padclear",
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

-- OS-boundary translation --
    -- macToVk: hs keyCode (mac) -> Win32 VK for SendInput. vkToMac: hook VK -> mac
    -- keyCode for the event surface. Both fall through to the input unchanged so an
    -- unknown code degrades to a best-effort pass rather than a nil crash.
    function keycodes.macToVk(code)
        return MAC_TO_VK[code] or code
    end

    function keycodes.vkToMac(vk)
        return VK_TO_MAC[vk] or vk
    end
-- END --

-- Compatibility stubs --
    -- Thread D owns only the static table. These exist so `require`rs that probe the
    -- fuller Hammerspoon surface don't nil-crash. Layout switching is a no-op on the
    -- single fixed layout the host assumes today; revisit if per-layout remapping lands.
    function keycodes.currentLayout()
        return "US"
    end

    function keycodes.currentSourceID()
        return "com.apple.keylayout.US"
    end

    function keycodes.keyCodeForName(name)
        return map[name]
    end

    function keycodes.nameForKeyCode(code)
        return map[code]
    end
-- END --

return keycodes
