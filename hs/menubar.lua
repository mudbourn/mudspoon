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

/* Native popup menu (user32). Nothing else in the tree declares these, so they
   are owned here. GetCursorPos/SetForegroundWindow ARE declared by other modules
   (mouse/focus/window/...), but LuaJIT tolerates an identical function redeclare
   and those owners may not be require()'d by the time a right-click fires, so we
   restate them here to guarantee they resolve on U. */
HMENU CreatePopupMenu(void);
BOOL  AppendMenuA(HMENU, UINT, uintptr_t, LPCSTR);
BOOL  TrackPopupMenu(HMENU, UINT, int, int, int, HWND, const RECT*);
BOOL  DestroyMenu(HMENU);
BOOL  GetCursorPos(POINT*);
BOOL  SetForegroundWindow(HWND);
BOOL  PostMessageA(HWND, UINT, WPARAM, LPARAM);
HICON LoadIconA(HINSTANCE, LPCSTR);
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
    local WM_NULL      = 0x0000

    -- Popup-menu flags.
    local MF_STRING    = 0x0000
    local MF_SEPARATOR = 0x0800
    local MF_GRAYED    = 0x0001
    local MF_DISABLED  = 0x0002
    local MF_CHECKED   = 0x0008

    local TPM_LEFTALIGN  = 0x0000
    local TPM_TOPALIGN   = 0x0000
    local TPM_RIGHTBUTTON = 0x0002
    local TPM_RETURNCMD  = 0x0100

    -- Stock icon (IDI_APPLICATION) as the last-ditch fallback so the tray is never blank.
    local IDI_APPLICATION = ffi.cast("LPCSTR", ffi.cast("uintptr_t", 32512))

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
            local rec = records[tonumber(wp)]
            if rec then
                if mouse == WM_RBUTTONUP then
                    -- Right-click: show the context menu (stored or default).
                    pcall(function() rec:popupMenu() end)
                elseif mouse == WM_LBUTTONUP then
                    -- Left-click: honour an explicit click callback; otherwise, if a
                    -- menu exists, show it (so a menu-only tray icon is still usable).
                    if rec._clickCb then
                        pcall(rec._clickCb, {})   -- upstream passes a modifiers table
                    else
                        pcall(function() rec:popupMenu() end)
                    end
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

    -- Bundled fallback icon: <this-module-dir>/assets/ms_icon.png. mudscript points
    -- setIcon at a generated .tiff that only its macOS build ever writes, so on Windows
    -- that path is missing and the tray would be blank. Resolve a repo-shipped PNG so
    -- there is always something to show. debug.getinfo gives this file's own path.
    local bundledIconPath = (function()
        local src = debug.getinfo(1, "S").source or ""
        src = src:gsub("^@", "")
        local dir = src:gsub("[^/\\]*$", "")
        return dir .. "assets/ms_icon.png"
    end)()

    -- Stock IDI_APPLICATION HICON (shared, never DestroyIcon'd -- it is system-owned).
    local stockHIcon = nil
    local function stockIcon()
        if stockHIcon == nil then
            local ok, h = pcall(function() return U.LoadIconA(nil, IDI_APPLICATION) end)
            stockHIcon = (ok and h ~= nil) and h or false
        end
        return stockHIcon or nil
    end

    -- Load `path`; on failure fall back to the bundled PNG, then the stock icon.
    -- The second return value is true when the HICON is owned by us (must be
    -- DestroyIcon'd on replace/delete) and false for the shared stock icon.
    local function loadHIconOrDefault(path)
        local h = path and loadHIcon(path)
        if h then return h, true end
        h = loadHIcon(bundledIconPath)
        if h then return h, true end
        return stockIcon(), false
    end
-- END --

-- Native Win32 popup menu (real, unlike the old inert stub) --
    -- hs.menubar menus are a list of items: { {title=, fn=, disabled=, checked=,
    -- menu=<sublist>}, ... }; title "-" is a separator. hs also allows a FUNCTION
    -- returning that list (rebuilt each popup). We map every actionable item to a
    -- Win32 command id, build an HMENU, and TrackPopupMenu with TPM_RETURNCMD so the
    -- chosen id comes back synchronously -- then dispatch its fn.
    local MF_POPUP = 0x0010

    local function resolveMenu(m)
        if type(m) == "function" then
            local ok, r = pcall(m)
            return ok and r or nil
        end
        return m
    end

    -- Build an HMENU for `items`; records id->fn in cmdMap; ids allocated via counter.
    local function buildMenu(items, cmdMap, counter)
        local hm = U.CreatePopupMenu()
        if hm == nil then return nil end
        for _, it in ipairs(items or {}) do
            local title = it.title
            if title == "-" or it.separator then
                U.AppendMenuA(hm, MF_SEPARATOR, 0, nil)
            elseif type(it.menu) == "table" then
                local sub = buildMenu(it.menu, cmdMap, counter)
                if sub ~= nil then
                    local buf = ffi.new("char[?]", #tostring(title or "") + 1)
                    ffi.copy(buf, tostring(title or ""))
                    U.AppendMenuA(hm, bit.bor(MF_STRING, MF_POPUP),
                                  ffi.cast("uintptr_t", sub), buf)
                end
            else
                local id = counter.n
                counter.n = id + 1
                cmdMap[id] = { fn = it.fn, item = it }
                local flags = MF_STRING
                if it.disabled then flags = bit.bor(flags, MF_GRAYED) end
                -- Upstream also honours state="on"/"off"/"mixed"; "on" == checked.
                if it.checked or it.state == "on" then flags = bit.bor(flags, MF_CHECKED) end
                local buf = ffi.new("char[?]", #tostring(title or "") + 1)
                ffi.copy(buf, tostring(title or ""))
                U.AppendMenuA(hm, flags, id, buf)
            end
        end
        return hm
    end

    -- Show `menu` (list or function) as a popup for tray object `self` at screen pt
    -- {x=,y=} (defaults to the cursor). Returns after the user picks or dismisses.
    local function showPopup(self, menu, pt)
        local items = resolveMenu(menu)
        if type(items) ~= "table" or #items == 0 then return end
        local cmdMap, counter = {}, { n = 1 }
        local hmenu = buildMenu(items, cmdMap, counter)
        if hmenu == nil then return end

        local x, y
        if type(pt) == "table" and pt.x then
            x, y = math.floor(pt.x), math.floor(pt.y)
        else
            local p = ffi.new("POINT")
            if U.GetCursorPos(p) ~= 0 then x, y = p.x, p.y else x, y = 0, 0 end
        end

        -- Foreground dance: without SetForegroundWindow before + a posted message
        -- after, the menu will not dismiss when the user clicks elsewhere (a
        -- documented Win32 quirk of TrackPopupMenu on a background window).
        U.SetForegroundWindow(self._hwnd)
        local flags = bit.bor(TPM_LEFTALIGN, TPM_TOPALIGN, TPM_RIGHTBUTTON, TPM_RETURNCMD)
        local cmd = tonumber(U.TrackPopupMenu(hmenu, flags, x, y, 0, self._hwnd, nil)) or 0
        U.PostMessageA(self._hwnd, WM_NULL, 0, 0)
        pcall(function() U.DestroyMenu(hmenu) end)   -- also frees submenus

        -- Upstream calls the item fn as fn(modifiers, itemTable). We do not track the
        -- modifier state at popup time, so pass an empty (but non-nil) table -- callers
        -- that write `function(mods) ... end` then index it safely instead of erroring.
        local hit = cmd > 0 and cmdMap[cmd]
        if hit and hit.fn then pcall(hit.fn, {}, hit.item) end
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

    -- Destroy the current icon only if WE own it (the stock icon is system-owned).
    local function dropIcon(self)
        if self._hicon and self._hiconOwned then
            pcall(function() U.DestroyIcon(self._hicon) end)
        end
        self._hicon, self._hiconOwned = nil, false
    end

    function Menubar:setIcon(path, _template)   -- template flag accepted + ignored
        if self._deleted then return self end
        -- Always resolve to SOMETHING: the given path, else the bundled PNG, else the
        -- stock app icon. A missing file must not leave the tray blank.
        local hicon, owned = loadHIconOrDefault(path)
        if hicon then
            dropIcon(self)
            self._hicon, self._hiconOwned = hicon, owned
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

    -- Store the menu (a list, or a function returning one). Shown on tray click and
    -- via :popupMenu. mudscript sets none, so tray objects fall back to the default
    -- menu installed in menubar.new (Console / Reload / Quit).
    function Menubar:setMenu(t) self._menu = t; return self end

    -- Draw the native popup now. pt is an optional {x=,y=} screen point; defaults to
    -- the cursor. Uses the stored menu (or the default) -- real, no longer inert.
    function Menubar:popupMenu(pt, _dark)
        if self._deleted then return self end
        showPopup(self, self._menu or self._defaultMenu, pt)
        return self
    end

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
        dropIcon(self)
        return self
    end
-- END --

-- Constructor --
    -- hs.menubar.new([inMenuBar]) -- inMenuBar defaults true. Adds the tray item now (icon
    -- set later via :setIcon). A false inMenuBar creates it detached (returnToMenuBar shows).
    -- Default right-click menu for a tray icon that no one gave an explicit menu to
    -- (mudscript never sets one on Windows). A FUNCTION so it is rebuilt per popup and
    -- picks up the mudscript API (_G.ms) once it has finished booting. Every action is
    -- guarded: it degrades to the hs-layer primitive, or no-ops, if ms is not up yet.
    local function defaultMenuItems()
        return {
            { title = "Open Console", fn = function()
                local ms = _G.ms
                if ms and ms.dev and ms.dev.console and ms.dev.console.toggle then
                    ms.dev.console.toggle()
                elseif _G.hs and hs.openConsole then
                    hs.openConsole()
                end
            end },
            { title = "Reload Config", fn = function()
                local ms = _G.ms
                if ms and ms.restart then ms.restart()
                elseif _G.hs and hs.reload then hs.reload() end
            end },
            { title = "-" },
            { title = "Quit mudscript", fn = function()
                local ms = _G.ms
                if ms and ms.shutdown then ms.shutdown()
                elseif _G.hs and hs.shutdown then hs.shutdown()
                else os.exit(0) end
            end },
        }
    end

    function menubar.new(inMenuBar)
        local hwnd = ensureMsgWindow()
        local self = setmetatable({
            _id          = nextId,
            _hwnd        = hwnd,
            _hicon       = nil,
            _hiconOwned  = false,
            _tip         = "mudscript",
            _clickCb     = nil,
            _menu        = nil,
            _defaultMenu = defaultMenuItems,   -- used until :setMenu overrides
            _deleted     = true,   -- flipped false by the NIM_ADD below when shown
        }, Menubar)
        nextId = nextId + 1

        -- Give it a visible icon up front so the tray is never blank, even if the
        -- caller never calls :setIcon or points it at a missing file. setIcon's own
        -- fallback chain (bundled PNG -> stock icon) picks the image.
        local hicon, owned = loadHIconOrDefault(nil)
        if hicon then self._hicon, self._hiconOwned = hicon, owned end

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
