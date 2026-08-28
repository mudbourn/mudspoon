-- hs.notify  (Win32 tray-balloon backend) --
    -- Hammerspoon's hs.notify posts a Notification Center banner. On Windows the closest
    -- flat-API analogue is a system-tray balloon (Shell_NotifyIcon with NIF_INFO), which
    -- reuses the plumbing built for hs.menubar. (A true toast via the WinRT
    -- ToastNotification API would need COM + an AppUserModelID; the balloon is the
    -- no-COM, always-available path.)
    --
    -- LIVE SURFACE mudscript uses (ms_core.lua:3879): hs.notify.new{title, subTitle,
    -- informativeText}:send(). That is the whole contract exercised. Windows balloons
    -- have only a title + a body, so subTitle is folded into the body.
    --
    -- Contract honoured:
    --   hs.notify.new(opts|nil) -> note   (opts: title, subTitle, informativeText)
    --     :send()      -- show the balloon (returns self)
    --     :withdraw()  -- remove the tray icon early (returns self)
    --     :release()   -- alias of withdraw (hs parity)
    --
    -- Each :send() adds a transient tray icon, shows the balloon, and auto-removes the
    -- icon after LINGER_S (reset if another send arrives first) so nothing lingers.
    --
    -- CDEF OWNERSHIP: NOTIFYICONDATAA + Shell_NotifyIconA + DestroyIcon are owned by
    -- hs.menubar; require it so they exist. This module cdefs ONLY LoadIconA (a default
    -- tray glyph) and MAKEINTRESOURCE-style icon ids. Window-creation prototypes come
    -- from hs.alert.window; base types from foundation.
-- END --

local ffi = require("ffi")
local bit = require("bit")

local host = require("hs.foundation")
require("hs.menubar")   -- owns NOTIFYICONDATAA / Shell_NotifyIconA / DestroyIcon cdefs

local U     = host.C.user32
local hInst = host.moduleHandle

local okShell, SH = pcall(ffi.load, "shell32")
if not okShell then SH = nil end

-- Own FFI surface (only symbols nothing else declares) --
    ffi.cdef[[
HICON LoadIconA(HINSTANCE, LPCSTR);
]]
-- END --

-- Constants --
    local NIM_ADD     = 0
    local NIM_MODIFY  = 1
    local NIM_DELETE  = 2

    local NIF_MESSAGE = 0x01
    local NIF_ICON    = 0x02
    local NIF_INFO    = 0x10

    local NIIF_INFO   = 0x01
    local IDI_INFORMATION = 32516   -- default system info glyph

    local WM_APP       = 0x8000
    local CALLBACK_MSG = WM_APP + 2   -- distinct from menubar's WM_APP+1

    local HWND_MESSAGE = ffi.cast("HWND", ffi.cast("intptr_t", -3))
    local TRAY_UID     = 0x4D53       -- 'MS'; single shared notify slot
    local LINGER_S     = 12

    local CLASS = "HammerspoonNotify"
-- END --

-- Shared hidden message window + one default icon (lazy) --
    -- jit.off: never JIT-trace a callback body (see hs.foundation) -- an error
    -- unwinding out of compiled mcode across the FFI boundary panics LuaJIT.
    local function wndProcFn(hwnd, msg, wp, lp)
        return U.DefWindowProcA(hwnd, msg, wp, lp)
    end
    jit.off(wndProcFn, true)
    local wndProc = ffi.cast("WNDPROC", wndProcFn)

    local classBuf = ffi.new("char[?]", #CLASS + 1)
    ffi.copy(classBuf, CLASS)

    local win, classReady, defIcon
    local function ensureWindow()
        if win then return win end
        if not classReady then
            local wc = ffi.new("WNDCLASSEXA")
            wc.cbSize        = ffi.sizeof("WNDCLASSEXA")
            wc.lpfnWndProc   = wndProc
            wc.hInstance     = hInst
            wc.lpszClassName = classBuf
            if U.RegisterClassExA(wc) == 0 then error("hs.notify: RegisterClassExA failed") end
            classReady = true
        end
        win = U.CreateWindowExA(0, classBuf, "", 0, 0, 0, 0, 0, HWND_MESSAGE, nil, hInst, nil)
        if win == nil then error("hs.notify: CreateWindowExA failed") end
        defIcon = U.LoadIconA(nil, ffi.cast("LPCSTR", IDI_INFORMATION))
        return win
    end

    -- Single shared tray state (all notes share one slot; balloons are sequential).
    local added, delTimer = false, nil

    local function removeIcon()
        if not (SH and added) then return end
        local nid = ffi.new("NOTIFYICONDATAA")
        nid.cbSize = ffi.sizeof("NOTIFYICONDATAA")
        nid.hWnd   = win
        nid.uID    = TRAY_UID
        SH.Shell_NotifyIconA(NIM_DELETE, nid)
        added = false
    end
-- END --

local notify = {}

-- Note object --
    local Note = {}
    Note.__index = Note

    function Note:send()
        if not SH then return self end
        ensureWindow()

        local nid = ffi.new("NOTIFYICONDATAA")
        nid.cbSize           = ffi.sizeof("NOTIFYICONDATAA")
        nid.hWnd             = win
        nid.uID              = TRAY_UID
        nid.uCallbackMessage = CALLBACK_MSG
        nid.uFlags           = bit.bor(NIF_MESSAGE, NIF_ICON, NIF_INFO)
        nid.hIcon            = defIcon
        nid.dwInfoFlags      = NIIF_INFO
        ffi.copy(nid.szInfoTitle, (self._title or "mudscript"):sub(1, 63))

        -- Windows balloons have title + body only; fold subTitle into the body.
        local body = self._info or ""
        if self._sub and #self._sub > 0 then
            body = (#body > 0) and (self._sub .. " -- " .. body) or self._sub
        end
        ffi.copy(nid.szInfo, body:sub(1, 255))

        SH.Shell_NotifyIconA(added and NIM_MODIFY or NIM_ADD, nid)
        added = true

        if delTimer then delTimer:cancel() end
        delTimer = host.schedule(LINGER_S * 1000, function() delTimer = nil; removeIcon() end)
        return self
    end

    function Note:withdraw()
        if delTimer then delTimer:cancel(); delTimer = nil end
        removeIcon()
        return self
    end
    Note.release = Note.withdraw
-- END --

-- Constructor --
    function notify.new(opts)
        opts = opts or {}
        return setmetatable({
            _title = opts.title and tostring(opts.title) or nil,
            _sub   = opts.subTitle and tostring(opts.subTitle) or nil,
            _info  = opts.informativeText and tostring(opts.informativeText) or nil,
        }, Note)
    end

    -- hs.notify.show(title, subTitle, info) convenience (hs parity; mudscript uses new).
    function notify.show(title, subTitle, info)
        return notify.new({ title = title, subTitle = subTitle, informativeText = info }):send()
    end
-- END --

return notify
