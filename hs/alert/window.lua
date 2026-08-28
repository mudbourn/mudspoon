-- hs.alert.window  (alert substrate, private) --
    -- The Win32/GDI mechanics under hs.alert: a borderless, rounded, translucent,
    -- click-through-less top-most popup with centred text. This is the DUMB half --
    -- it knows nothing about durations, fades, stacking, or Hammerspoon semantics.
    -- The policy half (hs.alert) drives it: sizing, positioning, the fade loop off
    -- the runloop, and the active-alert registry all live there.
    --
    -- Contract with hs.alert (frozen; the two were built in parallel against it):
    --
    --   window.show(text, { x, y, w, h, alpha, bg, fg }) -> handle
    --       x,y,w,h : screen-pixel rect (caller computes it, e.g. from hs.screen)
    --       alpha   : initial 0..255 opacity            (default 255)
    --       bg, fg  : COLORREF fill / text, 0x00BBGGRR   (defaults below)
    --   handle:setAlpha(byte)   -- 0..255, clamped; drives the caller's fade
    --   handle:close()          -- destroy the window; idempotent
    --
    -- Depends on FOUNDATION only, for shared TYPES + the loaded lib handles + the
    -- module instance handle. Per the frozen cdef-ownership rule, foundation owns
    -- every typedef (WNDCLASSEXA, PAINTSTRUCT, WNDPROC, HWND, HDC, RECT, HRGN ...);
    -- this module cdefs ONLY its own window/GDI FUNCTION prototypes, which no other
    -- module declares.
    --
    -- THREADING: every entry point here (show/setAlpha/close) touches the window on
    -- the calling thread. It MUST be the runloop/hook thread -- the one that pumps
    -- messages, so WM_PAINT reaches our WndProc. hs.alert only ever calls in from
    -- timer callbacks, which run on that thread, so this holds.
-- END --

local ffi = require("ffi")
local bit = require("bit")

-- Foundation: shared types, the loaded user32/gdi32, the module instance handle. --
    local host  = require("hs.foundation")
    local U     = host.C.user32
    local G     = host.C.gdi32
    local hInst = host.moduleHandle
-- END --

-- Own FFI surface (functions only; every type comes from foundation) --
    ffi.cdef[[
WORD    RegisterClassExA(const WNDCLASSEXA*);
HWND    CreateWindowExA(DWORD, LPCSTR, LPCSTR, DWORD, int, int, int, int, HWND, HMENU, HINSTANCE, void*);
BOOL    ShowWindow(HWND, int);
BOOL    DestroyWindow(HWND);
LRESULT DefWindowProcA(HWND, UINT, WPARAM, LPARAM);
BOOL    SetLayeredWindowAttributes(HWND, DWORD, BYTE, DWORD);
int     SetWindowRgn(HWND, HRGN, BOOL);
HDC     BeginPaint(HWND, PAINTSTRUCT*);
BOOL    EndPaint(HWND, const PAINTSTRUCT*);
BOOL    GetClientRect(HWND, RECT*);
int     FillRect(HDC, const RECT*, HBRUSH);
int     DrawTextA(HDC, LPCSTR, int, RECT*, UINT);
HBRUSH  CreateSolidBrush(DWORD);
HRGN    CreateRoundRectRgn(int, int, int, int, int, int);
BOOL    DeleteObject(HGDIOBJ);
int     SetBkMode(HDC, int);
DWORD   SetTextColor(HDC, DWORD);
]]
-- END --

-- Constants --
    local WS_POPUP          = 0x80000000
    local EX_LAYERED        = 0x00080000
    local EX_TOPMOST        = 0x00000008
    local EX_TOOLWINDOW     = 0x00000080  -- keep it out of the taskbar / alt-tab
    local EX_NOACTIVATE     = 0x08000000  -- never steal focus from the user
    local EX_STYLE          = bit.bor(EX_LAYERED, EX_TOPMOST, EX_TOOLWINDOW, EX_NOACTIVATE)

    local SW_SHOWNOACTIVATE = 4
    local LWA_ALPHA         = 0x02
    local TRANSPARENT       = 1           -- SetBkMode: don't paint behind glyphs

    local WM_PAINT          = 0x000F
    local WM_DESTROY        = 0x0002

    -- DrawTextA format: horizontally + vertically centred single line, and treat
    -- '&' literally rather than as an accelerator prefix.
    local DT_CENTER     = 0x00000001
    local DT_VCENTER    = 0x00000004
    local DT_SINGLELINE = 0x00000020
    local DT_NOPREFIX   = 0x00000800
    local DT_FORMAT     = bit.bor(DT_CENTER, DT_VCENTER, DT_SINGLELINE, DT_NOPREFIX)

    local ROUND         = 20             -- corner radius, px

    local DEFAULT_BG    = 0x001C1F24     -- deepslate; COLORREF is 0x00BBGGRR
    local DEFAULT_FG    = 0x00E8E8E8

    local CLASS         = "HammerspoonAlert"
-- END --

-- Per-window records, keyed by HWND-as-integer --
    -- The class shares ONE WndProc, so paint has to look up which window it is
    -- painting. Keying on the pointer value (not the cdata, which isn't a stable
    -- table key) gives each live window its own text + colours. Dropped on destroy.
    local records = {}

    local function keyOf(hwnd)
        return tonumber(ffi.cast("intptr_t", hwnd))
    end
-- END --

-- Window procedure (module scope: the GC must never free this cast) --
    -- A Lua error must NEVER unwind through this FFI boundary -- Windows calls it
    -- from inside DispatchMessage and a throw here is a hard crash. So the paint
    -- body is pcall-guarded; a bad paint yields a blank window, not a dead process.
    -- jit.off: never JIT-trace a callback body -- an error unwinding out of compiled
    -- mcode across the FFI boundary panics LuaJIT ("bad callback").
    local function wndProcFn(hwnd, msg, wp, lp)
        if msg == WM_PAINT then
            pcall(function()
                local rec = records[keyOf(hwnd)]

                local ps  = ffi.new("PAINTSTRUCT")
                local hdc = U.BeginPaint(hwnd, ps)
                local rc  = ffi.new("RECT")
                U.GetClientRect(hwnd, rc)

                local brush = G.CreateSolidBrush(rec and rec.bg or DEFAULT_BG)
                U.FillRect(hdc, rc, brush)
                G.DeleteObject(brush)

                if rec and rec.text and #rec.text > 0 then
                    G.SetBkMode(hdc, TRANSPARENT)
                    G.SetTextColor(hdc, rec.fg or DEFAULT_FG)
                    U.DrawTextA(hdc, rec.text, #rec.text, rc, DT_FORMAT)
                end

                U.EndPaint(hwnd, ps)
            end)
            return 0
        elseif msg == WM_DESTROY then
            return 0
        end
        return U.DefWindowProcA(hwnd, msg, wp, lp)
    end
    jit.off(wndProcFn, true)
    local wndProc = ffi.cast("WNDPROC", wndProcFn)
-- END --

-- Register the class once, lazily --
    -- The class name buffer is kept alive at module scope alongside the WndProc:
    -- Windows holds the lpszClassName pointer for the class's lifetime.
    local classBuf = ffi.new("char[?]", #CLASS + 1)
    ffi.copy(classBuf, CLASS)

    local registered = false
    local function ensureClass()
        if registered then return end
        local wc = ffi.new("WNDCLASSEXA")
        wc.cbSize        = ffi.sizeof("WNDCLASSEXA")
        wc.lpfnWndProc   = wndProc
        wc.hInstance     = hInst
        wc.lpszClassName = classBuf
        if U.RegisterClassExA(wc) == 0 then
            error("hs.alert.window: RegisterClassExA failed")
        end
        registered = true
    end
-- END --

-- Handle object --
    local Handle = {}
    Handle.__index = Handle

    -- setAlpha(byte): clamp to 0..255 and push to the layered window. No-op once
    -- closed, so a fade loop that overruns teardown by a tick does no harm.
    function Handle:setAlpha(a)
        if self._closed then return self end
        a = math.floor(a + 0.5)
        if a < 0 then a = 0 elseif a > 255 then a = 255 end
        U.SetLayeredWindowAttributes(self._hwnd, 0, a, LWA_ALPHA)
        return self
    end

    -- close(): destroy the window and forget its record. Idempotent -- the fade
    -- loop and an explicit closeAll() can both land here for the same window.
    function Handle:close()
        if self._closed then return self end
        self._closed = true
        records[self._key] = nil
        U.DestroyWindow(self._hwnd)
        return self
    end
-- END --

local window = {}

-- window.show(text, opts) -> handle --
    -- Create the layered popup at the caller's rect, register its text/colours for
    -- the shared WndProc, round its corners, set the initial alpha, and show it
    -- WITHOUT activating (so the user's focus and keyboard are never disturbed).
    function window.show(text, opts)
        opts = opts or {}
        ensureClass()

        local w = opts.w or 360
        local h = opts.h or 96
        local x = opts.x or 0
        local y = opts.y or 0

        local hwnd = U.CreateWindowExA(EX_STYLE, classBuf, "", WS_POPUP,
                                       x, y, w, h, nil, nil, hInst, nil)
        if hwnd == nil then
            error("hs.alert.window: CreateWindowExA failed")
        end

        -- Register paint state BEFORE the first show, so the initial WM_PAINT finds it.
        local key = keyOf(hwnd)
        records[key] = {
            text = text ~= nil and tostring(text) or "",
            bg   = opts.bg or DEFAULT_BG,
            fg   = opts.fg or DEFAULT_FG,
        }

        -- Rounded corners. SetWindowRgn takes ownership of the region on success,
        -- so we do NOT DeleteObject it. +1 on w/h because the region's far edge is
        -- exclusive; without it the bottom-right pixel row clips.
        U.SetWindowRgn(hwnd, G.CreateRoundRectRgn(0, 0, w + 1, h + 1, ROUND, ROUND), true)

        local alpha = opts.alpha or 255
        if alpha < 0 then alpha = 0 elseif alpha > 255 then alpha = 255 end
        U.SetLayeredWindowAttributes(hwnd, 0, alpha, LWA_ALPHA)

        U.ShowWindow(hwnd, SW_SHOWNOACTIVATE)

        return setmetatable({ _hwnd = hwnd, _key = key, _closed = false }, Handle)
    end
-- END --

return window
