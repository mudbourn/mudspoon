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
    -- The key tables are static. Layout calls load Win32 on first use.
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
        def("padclear", 71, 0x0C)
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

-- Keyboard layouts --
    -- Win32 handle, FFI declarations and lookups load on first use
    local W

    local function win()
        if W then return W end
        local ffi = require("ffi")
        local host = require("hs.foundation")
        ffi.cdef[[
HWND  GetForegroundWindow(void);
DWORD GetWindowThreadProcessId(HWND, DWORD*);
BOOL  PostMessageA(HWND, UINT, WPARAM, LPARAM);
void* GetKeyboardLayout(DWORD);
int   GetKeyboardLayoutList(int, void**);
int   GetLocaleInfoW(DWORD, DWORD, unsigned short*, int);
]]
        W = {
            ffi = ffi,
            U = host.C.user32,
            K = host.C.kernel32,
            buf = ffi.new("unsigned short[?]", 128),
            list = ffi.new("void*[?]", 64),
        }
        return W
    end

    local WM_INPUTLANGCHANGEREQUEST = 0x0050

    local LOCALE_SENGLISHDISPLAYNAME = 0x72

    local SPECIAL_NAMES = {
        [0x0409] = "U.S.",
        [0x0809] = "British",
    }

    local function langId(hkl)
        return tonumber(W.ffi.cast("uintptr_t", hkl)) % 0x10000
    end

    local function layoutName(hkl)
        local id = langId(hkl)
        if SPECIAL_NAMES[id] then return SPECIAL_NAMES[id] end
        local n = W.K.GetLocaleInfoW(id, LOCALE_SENGLISHDISPLAYNAME, W.buf, 128)
        if n <= 1 then return string.format("%04X", id) end
        local out = {}
        for i = 0, n - 2 do
            local c = W.buf[i]
            out[#out + 1] = c < 128 and string.char(c) or "?"
        end
        return table.concat(out)
    end

    local function isMethod(hkl)
        return tonumber(W.ffi.cast("uintptr_t", hkl)) % 0x100000000 >= 0xE0000000
    end

    local function foregroundThread()
        local hwnd = W.U.GetForegroundWindow()
        if hwnd == nil then return 0 end
        return W.U.GetWindowThreadProcessId(hwnd, nil)
    end

    local function currentHkl()
        return W.U.GetKeyboardLayout(foregroundThread())
    end

    -- Installed layouts as an array of { name, hkl }, filtered by isMethod
    local function installed(wantMethods)
        local n = W.U.GetKeyboardLayoutList(64, W.list)
        local out = {}
        for i = 0, n - 1 do
            local hkl = W.list[i]
            if isMethod(hkl) == wantMethods then
                out[#out + 1] = { name = layoutName(hkl), hkl = hkl }
            end
        end
        return out
    end

    local function activate(name, wantMethods)
        win()
        for _, l in ipairs(installed(wantMethods)) do
            if l.name == name then
                local hwnd = W.U.GetForegroundWindow()
                if hwnd == nil then return false end
                W.U.PostMessageA(hwnd, WM_INPUTLANGCHANGEREQUEST, 0, W.ffi.cast("intptr_t", l.hkl))
                return true
            end
        end
        return false
    end

    local function names(wantMethods)
        win()
        local out = {}
        for _, l in ipairs(installed(wantMethods)) do
            out[#out + 1] = l.name
        end
        return out
    end

    -- Name of the foreground window's keyboard layout
    function keycodes.currentLayout()
        win()
        return layoutName(currentHkl())
    end

    -- Names of the installed keyboard layouts
    function keycodes.layouts()
        return names(false)
    end

    -- Switches the foreground window's layout by name and returns whether it was found
    function keycodes.setLayout(name)
        return activate(name, false)
    end

    -- Stable identifier of the current layout
    function keycodes.currentSourceID()
        win()
        return string.format("com.microsoft.keylayout.%04X", langId(currentHkl()))
    end

    -- Name of the current input method (IME), nil when the layout is not one
    function keycodes.currentMethod()
        win()
        local hkl = currentHkl()
        if isMethod(hkl) then return layoutName(hkl) end
        return nil
    end

    -- Names of the installed input methods
    function keycodes.methods()
        return names(true)
    end

    -- Switches the foreground window's input method by name
    function keycodes.setMethod(name)
        return activate(name, true)
    end
-- END --

-- Input source change callback --
    local watchTimer
    local lastSource

    -- Calls fn when the current layout changes. Passing nil removes the callback.
    function keycodes.inputSourceChanged(fn)
        if watchTimer then
            watchTimer:stop()
            watchTimer = nil
        end
        if type(fn) ~= "function" then return end
        lastSource = keycodes.currentSourceID()
        watchTimer = require("hs.timer").doEvery(0.25, function()
            local now = keycodes.currentSourceID()
            if now ~= lastSource then
                lastSource = now
                pcall(fn)
            end
        end)
    end
-- END --

-- Name and code lookups --
    function keycodes.keyCodeForName(name)
        return map[name]
    end

    function keycodes.nameForKeyCode(code)
        return map[code]
    end
-- END --

return keycodes
