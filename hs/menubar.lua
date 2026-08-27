-- hs.menubar  (Win32 system-tray backend via Shell_NotifyIcon) --
    -- Hammerspoon's hs.menubar puts a clickable item in the macOS menu bar. On Windows
    -- the analogue is a notification-area (system tray) icon, driven by Shell_NotifyIcon.
    --
    -- LIVE SURFACE mudscript actually uses (ms_settings.lua): new() -> setIcon(path,
    -- template) -> delete(). That is a tray PRESENCE icon, nothing clickable: mudscript's
    -- native-menu path is dead by design (_legacyNativeMenuBuilder is never called,
    -- ms._menuOpen never goes true, so :popupMenu is unreachable) and the project moved
    -- OFF native menus deliberately (see the shell UI). So the menu / popup methods here
    -- are present for hs parity + forward compat but are INTENTIONALLY INERT -- they never
    -- draw a native Win32 menu. setIcon is the load-bearing one.
    --
    -- Contract honoured:
    --   hs.menubar.new([inMenuBar]) -> menubar object (adds a tray icon)
    --     :setIcon(path[, template])   -- path to an image file (tiff/png/ico/bmp); the
    --                                     macOS `template` flag is accepted + ignored
    --                                     (the tray has no template-image concept)
    --     :setTooltip(text) / :setTitle(text)  -- tooltip sets the hover text; title is
    --                                             a no-op (a tray icon carries no label)
    --     :setClickCallback(fn)        -- fn() on a left/right click (stored + wired, but
    --                                     mudscript sets none, so usually never fires)
    --     :setMenu(t) / :popupMenu(pt) -- stored / no-op: INERT by design (no native menu)
    --     :removeFromMenuBar() / :returnToMenuBar() / :isInMenuBar()
    --     :delete()                    -- remove the tray icon (idempotent)
    --
    -- ICON PATH: the image is loaded with GDI+ (so .tiff works, which LoadImage cannot)
    -- and converted to an HICON via GdipCreateHICONFromBitmap. GDI+ startup + the
    -- Gdip{LoadImageFromFile,DisposeImage} cdefs are OWNED BY hs.canvas; require it so
    -- those exist and GDI+ is initialised before we touch them.
    --
    -- CDEF OWNERSHIP: the window-creation prototypes (CreateWindowExA/RegisterClassExA/
    -- ShowWindow/DestroyWindow/DefWindowProcA) are declared by hs.alert.window, which
    -- loads first (realExtra), and the WNDCLASSEXA/WNDPROC/HICON/POINT types by
    -- foundation. This module cdefs ONLY what nothing else owns: Shell_NotifyIconA +
    -- NOTIFYICONDATAA, GdipCreateHICONFromBitmap, and DestroyIcon.
    --
    -- THREADING: every entry point touches the tray on the calling thread, which must be
    -- the runloop/pump thread (the shared WndProc is serviced by that pump). mudscript
    -- only ever calls menubar from the boot thread / timer callbacks.
-- END --

local ffi = require("ffi")
local bit = require("bit")

local host = require("hs.foundation")
require("hs.canvas")   -- ensures GDI+ is started + Gdip{LoadImageFromFile,DisposeImage} cdef'd

local U     = host.C.user32
local hInst = host.moduleHandle

-- gdiplus: reuse the DLL canvas already started. Guard the load so a missing DLL leaves
-- the tray icon blank (no HICON) rather than crashing boot.
local okGP, GP = pcall(ffi.load, "gdiplus")
if not okGP then GP = nil end

-- shell32: Shell_NotifyIcon lives here. Guarded the same way -- no shell32 => no tray.
local okShell, SH = pcall(ffi.load, "shell32")
if not okShell then SH = nil end

-- Own FFI surface (only symbols nothing else declares) --
    ffi.cdef[[
/* system tray (shell32) */
typedef struct {
    DWORD cbSize;
    HWND  hWnd;
    UINT  uID;
    UINT  uFlags;
    UINT  uCallbackMessage;
    HICON hIcon;
    char  szTip[128];
    DWORD dwState;
    DWORD dwStateMask;
    char  szInfo[256];
    UINT  uVersion;            /* union{uTimeout,uVersion} -- we only set uVersion */
    char  szInfoTitle[64];
    DWORD dwInfoFlags;
    char  guidItem[16];        /* GUID (unused: left zeroed) */
    HICON hBalloonIcon;
} NOTIFYICONDATAA;
BOOL Shell_NotifyIconA(DWORD, NOTIFYICONDATAA*);

/* icon lifetime (user32) */
BOOL DestroyIcon(HICON);

/* GDI+ image -> HICON (gdiplus); Load/Dispose are owned by hs.canvas */
int GdipCreateHICONFromBitmap(void*, void**);
]]
-- END --

-- Constants --
    local NIM_ADD     = 0
    local NIM_MODIFY  = 1
    local NIM_DELETE  = 2

    local NIF_MESSAGE = 0x01
    local NIF_ICON    = 0x02
    local NIF_TIP     = 0x04

    local WM_APP       = 0x8000
    local CALLBACK_MSG = WM_APP + 1

    local WM_LBUTTONUP = 0x0202
    local WM_RBUTTONUP = 0x0205

    local HWND_MESSAGE = ffi.cast("HWND", ffi.cast("intptr_t", -3))

    local CLASS = "MudspoonMenubar"
-- END --

-- Shared hidden message window (one per process; there is only ever one menubar) --
    -- Tray callbacks are delivered as CALLBACK_MSG to this window: wParam = the icon uID,
    -- lParam = the mouse message. We route left/right button-up to the icon's click cb.
    local records = {}   -- uID -> menubar object

    -- jit.off: never JIT-trace a callback body -- an error unwinding out of compiled
    -- mcode across the FFI boundary panics LuaJIT ("bad callback").
    local function wndProcFn(hwnd, msg, wp, lp)
        if msg == CALLBACK_MSG then
            local mouse = bit.band(tonumber(lp), 0xFFFF)
            if mouse == WM_LBUTTONUP or mouse == WM_RBUTTONUP then
                local rec = records[tonumber(wp)]
                if rec and rec._clickCb then
                    pcall(rec._clickCb)
                end
            end
            return 0
        end
        return U.DefWindowProcA(hwnd, msg, wp, lp)
    end
    jit.off(wndProcFn, true)
    local wndProc = ffi.cast("WNDPROC", wndProcFn)

    local classBuf = ffi.new("char[?]", #CLASS + 1)
    ffi.copy(classBuf, CLASS)

    local msgWin, classReady
    local function ensureMsgWindow()
        if msgWin then return msgWin end
        if not classReady then
            local wc = ffi.new("WNDCLASSEXA")
            wc.cbSize        = ffi.sizeof("WNDCLASSEXA")
            wc.lpfnWndProc   = wndProc
            wc.hInstance     = hInst
            wc.lpszClassName = classBuf
            if U.RegisterClassExA(wc) == 0 then
                error("hs.menubar: RegisterClassExA failed")
            end
            classReady = true
        end
        -- Message-only window: HWND_MESSAGE parent, never shown, just a callback sink.
        msgWin = U.CreateWindowExA(0, classBuf, "", 0, 0, 0, 0, 0,
                                   HWND_MESSAGE, nil, hInst, nil)
        if msgWin == nil then error("hs.menubar: CreateWindowExA failed") end
        return msgWin
    end
-- END --

-- Icon loading: image file -> HICON via GDI+ (tiff-capable, unlike LoadImage) --
    -- UTF-8 path -> UTF-16 for the wide GDI+ API, reusing the pure-Lua converter is
    -- overkill here; GDI+ wants a wchar path, so build one inline. ASCII paths dominate;
    -- non-ASCII is byte-widened (best-effort, matches the tree-wide ANSI posture).
    local function wpath(s)
        s = tostring(s or "")
        local buf = ffi.new("unsigned short[?]", #s + 1)
        for i = 1, #s do buf[i - 1] = s:byte(i) end
        buf[#s] = 0
        return buf
    end

    -- Returns an HICON (ffi cdata) or nil. Caller owns it (DestroyIcon on replace/delete).
    local function loadHIcon(path)
        if not GP then return nil end
        local img = ffi.new("void*[1]")
        local hicon = nil
        pcall(function()
            if GP.GdipLoadImageFromFile(wpath(path), img) == 0 and img[0] ~= nil then
                local out = ffi.new("void*[1]")
                if GP.GdipCreateHICONFromBitmap(img[0], out) == 0 and out[0] ~= nil then
                    hicon = ffi.cast("HICON", out[0])
                end
            end
        end)
        if img[0] ~= nil then pcall(function() GP.GdipDisposeImage(img[0]) end) end
        return hicon
    end
-- END --

local menubar = {}

-- Menubar object --
    local Menubar = {}
    Menubar.__index = Menubar

    local nextId = 1

    -- Fill a NOTIFYICONDATAA for this object with the current tip/icon and push `op`.
    local function notify(self, op)
        if not SH or not self._hwnd then return false end
        local nid = ffi.new("NOTIFYICONDATAA")
        nid.cbSize           = ffi.sizeof("NOTIFYICONDATAA")
        nid.hWnd             = self._hwnd
        nid.uID              = self._id
        nid.uCallbackMessage = CALLBACK_MSG
        local flags = NIF_MESSAGE
        if self._hicon then flags = bit.bor(flags, NIF_ICON); nid.hIcon = self._hicon end
        if self._tip then
            flags = bit.bor(flags, NIF_TIP)
            ffi.copy(nid.szTip, self._tip:sub(1, 127))
        end
        nid.uFlags = flags
        return SH.Shell_NotifyIconA(op, nid) ~= 0
    end

    function Menubar:setIcon(path, _template)   -- template flag accepted + ignored
        if self._deleted then return self end
        local hicon = loadHIcon(path)
        if hicon then
            if self._hicon then pcall(function() U.DestroyIcon(self._hicon) end) end
            self._hicon = hicon
            notify(self, NIM_MODIFY)
        end
        return self
    end

    function Menubar:setTooltip(text)
        self._tip = text and tostring(text) or nil
        if not self._deleted then notify(self, NIM_MODIFY) end
        return self
    end

    -- A tray icon carries no visible label; title is a no-op (hs parity).
    function Menubar:setTitle(_) return self end

    function Menubar:setClickCallback(fn)
        self._clickCb = (type(fn) == "function") and fn or nil
        return self
    end

    -- INERT by design: mudscript uses the shell UI, not native menus (no-native-selects).
    function Menubar:setMenu(t) self._menu = t; return self end
    function Menubar:popupMenu(_pt, _dark) return self end

    function Menubar:isInMenuBar() return not self._deleted end

    function Menubar:removeFromMenuBar()
        if self._deleted then return self end
        notify(self, NIM_DELETE)
        records[self._id] = nil
        self._deleted = true
        return self
    end

    -- Re-add after removeFromMenuBar (hs parity; mudscript does not use it).
    function Menubar:returnToMenuBar()
        if not self._deleted then return self end
        self._hwnd = ensureMsgWindow()
        records[self._id] = self
        self._deleted = false
        notify(self, NIM_ADD)
        return self
    end

    function Menubar:frame() return nil end   -- tray geometry not exposed

    function Menubar:delete()
        if self._deleted then return self end
        notify(self, NIM_DELETE)
        records[self._id] = nil
        self._deleted = true
        if self._hicon then pcall(function() U.DestroyIcon(self._hicon) end); self._hicon = nil end
        return self
    end
-- END --

-- Constructor --
    -- hs.menubar.new([inMenuBar]) -- inMenuBar defaults true. Adds the tray item now (icon
    -- set later via :setIcon). A false inMenuBar creates it detached (returnToMenuBar shows).
    function menubar.new(inMenuBar)
        local hwnd = ensureMsgWindow()
        local self = setmetatable({
            _id      = nextId,
            _hwnd    = hwnd,
            _hicon   = nil,
            _tip     = "mudscript",
            _clickCb = nil,
            _menu    = nil,
            _deleted = true,   -- flipped false by the NIM_ADD below when shown
        }, Menubar)
        nextId = nextId + 1

        if inMenuBar == false then
            return self   -- detached; returnToMenuBar() will add it
        end
        records[self._id] = self
        self._deleted = false
        notify(self, NIM_ADD)
        return self
    end

    -- hs.menubar.new* variants Hammerspoon exposes; mudscript uses none, alias for safety.
    menubar.newWithPriority = function(_, ...) return menubar.new(...) end
    menubar.priorities = { default = 1000, notificationCenter = 2147483647,
                           spotlight = 2147483646, system = 2147483645 }
-- END --

return menubar
