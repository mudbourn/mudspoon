-- hs.menubar --
    -- Menu objects with a native Win32 popup menu. The notification-area icon belongs
    -- to tray.ps1, so menubar objects never add one.
-- END --

local ffi = require("ffi")
local bit = require("bit")

local host = require("hs.foundation")

local U     = host.C.user32
local hInst = host.moduleHandle

-- Own FFI surface --
    ffi.cdef[[
HMENU CreatePopupMenu(void);
BOOL  AppendMenuA(HMENU, UINT, uintptr_t, LPCSTR);
BOOL  TrackPopupMenu(HMENU, UINT, int, int, int, HWND, const RECT*);
BOOL  DestroyMenu(HMENU);
BOOL  GetCursorPos(POINT*);
BOOL  SetForegroundWindow(HWND);
BOOL  PostMessageA(HWND, UINT, WPARAM, LPARAM);
]]
-- END --

-- Constants --
    local WM_NULL = 0x0000

    local MF_STRING    = 0x0000
    local MF_GRAYED    = 0x0001
    local MF_CHECKED   = 0x0008
    local MF_POPUP     = 0x0010
    local MF_SEPARATOR = 0x0800

    local TPM_LEFTALIGN   = 0x0000
    local TPM_TOPALIGN    = 0x0000
    local TPM_RIGHTBUTTON = 0x0002
    local TPM_RETURNCMD   = 0x0100

    local HWND_MESSAGE = ffi.cast("HWND", ffi.cast("intptr_t", -3))

    local CLASS = "HammerspoonMenubar"
-- END --

-- Owner window for popup menus --
    local function wndProcFn(hwnd, msg, wp, lp)
        return U.DefWindowProcA(hwnd, msg, wp, lp)
    end

    jit.off(wndProcFn, true)

    local wndProc = ffi.cast("WNDPROC", wndProcFn)

    local classBuf = ffi.new("char[?]", #CLASS + 1)

    ffi.copy(classBuf, CLASS)

    local msgWin

    local function ensureMsgWindow()
        if msgWin then return msgWin end

        local wc = ffi.new("WNDCLASSEXA")

        wc.cbSize        = ffi.sizeof("WNDCLASSEXA")
        wc.lpfnWndProc   = wndProc
        wc.hInstance     = hInst
        wc.lpszClassName = classBuf

        if U.RegisterClassExA(wc) == 0 then error("hs.menubar: RegisterClassExA failed") end

        msgWin = U.CreateWindowExA(0, classBuf, "", 0, 0, 0, 0, 0, HWND_MESSAGE, nil, hInst, nil)

        if msgWin == nil then error("hs.menubar: CreateWindowExA failed") end

        return msgWin
    end
-- END --

-- Native popup menu --
    local function resolveMenu(m)
        if type(m) ~= "function" then return m end

        local ok, r = pcall(m)

        return ok and r or nil
    end

    local function cstr(s)
        s = tostring(s or "")

        local buf = ffi.new("char[?]", #s + 1)

        ffi.copy(buf, s)

        return buf
    end

    local function buildMenu(items, cmdMap, counter)
        local hm = U.CreatePopupMenu()

        if hm == nil then return nil end

        for _, it in ipairs(items or {}) do
            if it.title == "-" or it.separator then
                U.AppendMenuA(hm, MF_SEPARATOR, 0, nil)
            elseif type(it.menu) == "table" then
                local sub = buildMenu(it.menu, cmdMap, counter)

                if sub ~= nil then
                    U.AppendMenuA(hm, bit.bor(MF_STRING, MF_POPUP), ffi.cast("uintptr_t", sub), cstr(it.title))
                end
            else
                local id = counter.n

                counter.n = id + 1

                cmdMap[id] = {
                    fn = it.fn,
                    item = it,
                }

                local flags = MF_STRING

                if it.disabled then flags = bit.bor(flags, MF_GRAYED) end

                if it.checked or it.state == "on" then flags = bit.bor(flags, MF_CHECKED) end

                U.AppendMenuA(hm, flags, id, cstr(it.title))
            end
        end

        return hm
    end

    local function showPopup(menu, pt)
        local items = resolveMenu(menu)

        if type(items) ~= "table" or #items == 0 then return end

        local cmdMap = {}

        local hmenu = buildMenu(items, cmdMap, { n = 1 })

        if hmenu == nil then return end

        local x, y = 0, 0

        if type(pt) == "table" and pt.x then
            x, y = math.floor(pt.x), math.floor(pt.y)
        else
            local p = ffi.new("POINT")

            if U.GetCursorPos(p) ~= 0 then x, y = p.x, p.y end
        end

        local hwnd = ensureMsgWindow()

        U.SetForegroundWindow(hwnd)

        local flags = bit.bor(TPM_LEFTALIGN, TPM_TOPALIGN, TPM_RIGHTBUTTON, TPM_RETURNCMD)

        local cmd = tonumber(U.TrackPopupMenu(hmenu, flags, x, y, 0, hwnd, nil)) or 0

        U.PostMessageA(hwnd, WM_NULL, 0, 0)

        pcall(function() U.DestroyMenu(hmenu) end)

        local hit = cmd > 0 and cmdMap[cmd]

        if hit and hit.fn then pcall(hit.fn, {}, hit.item) end
    end
-- END --

local menubar = {}

-- Menubar object --
    local Menubar = {}

    Menubar.__index = Menubar

    function Menubar:setIcon(path, _template)
        self._icon = path

        return self
    end

    function Menubar:setTooltip(text)
        self._tip = text and tostring(text) or nil

        return self
    end

    function Menubar:setTitle(text)
        self._title = text

        return self
    end

    function Menubar:setClickCallback(fn)
        self._clickCb = (type(fn) == "function") and fn or nil

        return self
    end

    function Menubar:setMenu(t)
        self._menu = t

        return self
    end

    function Menubar:popupMenu(pt, _dark)
        if not self._deleted then showPopup(self._menu, pt) end

        return self
    end

    function Menubar:isInMenuBar()
        return self._inMenuBar and not self._deleted
    end

    function Menubar:removeFromMenuBar()
        self._inMenuBar = false

        return self
    end

    function Menubar:returnToMenuBar()
        self._inMenuBar = true

        return self
    end

    function Menubar:frame()
        return nil
    end

    function Menubar:delete()
        self._deleted = true

        return self
    end
-- END --

-- Constructor --
    function menubar.new(inMenuBar)
        return setmetatable({
            _inMenuBar = inMenuBar ~= false,
            _deleted = false,
        }, Menubar)
    end

    menubar.newWithPriority = function(_, ...) return menubar.new(...) end

    menubar.priorities = {
        default = 1000,
        notificationCenter = 2147483647,
        spotlight = 2147483646,
        system = 2147483645,
    }
-- END --

return menubar
