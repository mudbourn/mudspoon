-- hs.canvas  (Win32/GDI backend for the element subset mudscript draws) --
    -- Hammerspoon's hs.canvas is a full vector surface; mudscript uses a narrow
    -- slice of it -- ms_alert draws each toast as ONE canvas: a rounded, translucent
    -- rectangle (fill + 1px accent stroke) plus two centred text elements (the
    -- message and a close glyph). This module implements exactly that slice over a
    -- borderless, layered, top-most GDI popup -- the same substrate shape as
    -- hs.alert.window, generalised to a mutable element list.
    --
    -- Contract mudscript relies on (see mac/lib/ms_alert.lua):
    --   hs.canvas.windowLevels / .windowBehaviors  -- numeric tables read at load
    --   hs.canvas.new({x,y,w,h}) -> canvas
    --     :level(n) :behavior(n) :alpha([a])   -- a in 0..1
    --     :frame([{x,y,w,h}])                   -- get (copy) / set (moves+resizes)
    --     :appendElements(el, ...)              -- rectangle | text specs
    --     :elementAttribute(i, key, value)      -- mutate one element, repaint
    --     :mouseCallback(fn)  -- fn(canvas, msg, elemId, x, y); msg =
    --                            "mouseEnter"|"mouseExit"|"mouseDown"
    --     :show() :delete()   -- delete is idempotent
    --
    -- Element specs honoured:
    --   rectangle: fillColor, strokeColor, strokeWidth, roundedRectRadii.xRadius
    --   text:      text, textFont, textSize, textColor, textAlignment, frame{x,y,w,h}
    -- Colours are Hammerspoon tables {red,green,blue,alpha} in 0..1.
    --
    -- FIDELITY NOTES (deliberate, first-pass):
    --   * GDI gives ONE whole-window alpha (SetLayeredWindowAttributes), not
    --     per-pixel. So a fillColor's own alpha and the animated :alpha() are
    --     MULTIPLIED into that single window alpha; a text element's alpha is faked
    --     by blending its colour toward the box fill (the box is opaque behind it),
    --     which is what the close-glyph fade and the morph cross-fade need.
    --
    -- THREADING: every entry point touches the window on the calling thread, which
    -- must be the runloop/pump thread (so WM_PAINT reaches our WndProc). mudscript
    -- only drives canvases from timer callbacks, which run there.
    --
    -- CDEF OWNERSHIP: foundation owns every shared typedef; this module cdefs ONLY
    -- function prototypes no other loaded module declares. It does NOT touch
    -- MultiByteToWideChar (webview owns that, conditionally) -- UTF-8 -> UTF-16 is
    -- done in pure Lua below, so canvas is independent of whether webview loaded.
-- END --

local ffi = require("ffi")
local bit = require("bit")

local host  = require("hs.foundation")
local U     = host.C.user32
local G     = host.C.gdi32
local hInst = host.moduleHandle

-- Own FFI surface: only prototypes nothing else has declared globally --
    -- (RegisterClassExA/CreateWindowExA/ShowWindow/DestroyWindow/DefWindowProcA/
    -- BeginPaint/EndPaint/GetClientRect/FillRect/DrawTextA/CreateSolidBrush/
    -- CreateRoundRectRgn/DeleteObject/SetBkMode/SetTextColor/SetWindowRgn/
    -- SetLayeredWindowAttributes/SetWindowPos/MoveWindow are all declared by
    -- foundation / hs.alert.window / hs.window and reached via U./G. below.)
    ffi.cdef[[
BOOL    InvalidateRect(HWND, const RECT*, BOOL);
int     FrameRgn(HDC, HRGN, HBRUSH, int, int);
HGDIOBJ SelectObject(HDC, HGDIOBJ);
void*   CreateFontW(int,int,int,int,int,DWORD,DWORD,DWORD,DWORD,DWORD,DWORD,DWORD,DWORD,const unsigned short*);
int     DrawTextW(HDC, const unsigned short*, int, RECT*, UINT);
typedef struct { DWORD cbSize; DWORD dwFlags; HWND hwndTrack; DWORD dwHoverTime; } MUDSPOON_TME;
BOOL    TrackMouseEvent(MUDSPOON_TME*);
]]
-- END --

-- Constants --
    local WS_POPUP          = 0x80000000
    local EX_LAYERED        = 0x00080000
    local EX_TOPMOST        = 0x00000008
    local EX_TOOLWINDOW     = 0x00000080
    local EX_NOACTIVATE     = 0x08000000
    local EX_STYLE          = bit.bor(EX_LAYERED, EX_TOPMOST, EX_TOOLWINDOW, EX_NOACTIVATE)

    local SW_SHOWNOACTIVATE = 4
    local LWA_ALPHA         = 0x02
    local TRANSPARENT       = 1

    local HWND_TOPMOST      = ffi.cast("HWND", ffi.cast("intptr_t", -1))
    local SWP_NOSIZE        = 0x0001
    local SWP_NOMOVE        = 0x0002
    local SWP_NOACTIVATE    = 0x0010
    local SWP_FRONT         = bit.bor(SWP_NOSIZE, SWP_NOMOVE, SWP_NOACTIVATE)

    local WM_DESTROY        = 0x0002
    local WM_PAINT          = 0x000F
    local WM_MOUSEMOVE      = 0x0200
    local WM_LBUTTONDOWN    = 0x0201
    local WM_MOUSELEAVE     = 0x02A3
    local TME_LEAVE         = 0x00000002

    -- DrawTextW formats. Long / multi-line text (the message) wraps and hangs from
    -- the top of its frame; short text (the close glyph) centres on both axes.
    local DT_CENTER     = 0x00000001
    local DT_VCENTER    = 0x00000004
    local DT_WORDBREAK  = 0x00000010
    local DT_SINGLELINE = 0x00000020
    local DT_NOPREFIX   = 0x00000800
    local FMT_WRAP      = bit.bor(DT_CENTER, DT_WORDBREAK, DT_NOPREFIX)
    local FMT_GLYPH     = bit.bor(DT_CENTER, DT_VCENTER, DT_SINGLELINE, DT_NOPREFIX)

    -- Font: DEFAULT_CHARSET, CLEARTYPE_QUALITY, normal weight. Point size -> device
    -- height at ~96dpi (1pt ~= 1.333px); negative asks for character (not cell) height.
    local FW_NORMAL         = 400
    local DEFAULT_CHARSET   = 1
    local CLEARTYPE_QUALITY = 5
    local PX_PER_PT         = 96 / 72

    local DEFAULT_RADIUS    = 20
    local DEFAULT_BG        = 0x001C1F24    -- COLORREF 0x00BBGGRR
    local DEFAULT_FG        = 0x00E8E8E8

    local CLASS             = "MudspoonCanvas"
-- END --

-- Colour helpers --
    -- Hammerspoon colours are {red,green,blue,alpha} in 0..1. -> COLORREF 0x00BBGGRR.
    local function toRef(c, fallback)
        if type(c) ~= "table" or c.red == nil then return fallback end
        local r = math.floor((c.red   or 0) * 255 + 0.5)
        local g = math.floor((c.green or 0) * 255 + 0.5)
        local b = math.floor((c.blue  or 0) * 255 + 0.5)
        return r + g * 256 + b * 65536
    end

    local function alphaOf(c, default)
        if type(c) == "table" and c.alpha ~= nil then return c.alpha end
        return default
    end

    -- Blend a COLORREF toward another by (1-a): fakes per-element text alpha against
    -- the opaque box behind it.
    local function blendRef(fg, bg, a)
        if a >= 1 then return fg end
        if a <= 0 then return bg end
        local function ch(v, shift)
            local f = bit.band(bit.rshift(v, shift), 0xFF)
            local b = bit.band(bit.rshift(bg, shift), 0xFF)
            return math.floor(b + (f - b) * a + 0.5)
        end
        return ch(fg, 0) + ch(fg, 8) * 256 + ch(fg, 16) * 65536
    end
-- END --

-- UTF-8 -> UTF-16 (pure Lua; no MultiByteToWideChar dependency) --
    -- Returns an ffi uint16[?] buffer (NUL-terminated). Malformed bytes are skipped.
    -- Handles the full BMP plus astral planes (surrogate pairs) so em-dashes,
    -- bullets, and the close glyph render correctly through DrawTextW.
    local function toWide(s)
        s = tostring(s or "")
        local units, i, n = {}, 1, #s
        while i <= n do
            local c = s:byte(i)
            local cp, len
            if     c < 0x80 then cp, len = c, 1
            elseif c < 0xE0 then cp, len = bit.band(c, 0x1F), 2
            elseif c < 0xF0 then cp, len = bit.band(c, 0x0F), 3
            else                 cp, len = bit.band(c, 0x07), 4 end
            for k = 1, len - 1 do
                local cc = s:byte(i + k)
                if not cc or cc < 0x80 or cc >= 0xC0 then cp = nil; break end
                cp = cp * 0x40 + bit.band(cc, 0x3F)
            end
            i = i + len
            if cp then
                if cp > 0xFFFF then
                    cp = cp - 0x10000
                    units[#units + 1] = 0xD800 + bit.rshift(cp, 10)
                    units[#units + 1] = 0xDC00 + bit.band(cp, 0x3FF)
                else
                    units[#units + 1] = cp
                end
            end
        end
        local buf = ffi.new("unsigned short[?]", #units + 1)
        for k = 1, #units do buf[k - 1] = units[k] end
        buf[#units] = 0
        return buf
    end
-- END --

-- Per-window records for the shared WndProc, keyed by HWND-as-integer --
    local records = {}
    local function keyOf(hwnd) return tonumber(ffi.cast("intptr_t", hwnd)) end

    -- Hit-test: the top-most element (highest index) whose frame contains (x,y).
    -- The rectangle (index 1, no frame) is the whole client, so it always matches
    -- as the fallback. Returns the 1-based element id.
    local function hitTest(rec, x, y)
        for idx = #rec.elements, 1, -1 do
            local el = rec.elements[idx]
            local f  = el.frame
            if f and x >= f.x and x <= f.x + f.w and y >= f.y and y <= f.y + f.h then
                return idx
            end
        end
        return 1
    end
-- END --

-- Painting --
    local function paint(rec, hwnd)
        local ps  = ffi.new("PAINTSTRUCT")
        local hdc = U.BeginPaint(hwnd, ps)
        local rc  = ffi.new("RECT")
        U.GetClientRect(hwnd, rc)
        local w, h = rc.right - rc.left, rc.bottom - rc.top

        local els  = rec.elements
        local box  = els[1]
        local bgRef = box and toRef(box.fillColor, DEFAULT_BG) or DEFAULT_BG

        -- Fill (the rounded window region already clips this to a rounded box).
        local brush = G.CreateSolidBrush(bgRef)
        U.FillRect(hdc, rc, brush)
        G.DeleteObject(brush)

        -- 1px+ accent stroke, following the same rounded region.
        if box and box.strokeColor and (box.strokeWidth or 0) > 0 then
            local rgn = G.CreateRoundRectRgn(0, 0, w + 1, h + 1, rec.radius, rec.radius)
            local sb  = G.CreateSolidBrush(toRef(box.strokeColor, DEFAULT_FG))
            U.FrameRgn(hdc, rgn, sb, box.strokeWidth, box.strokeWidth)
            G.DeleteObject(sb)
            G.DeleteObject(rgn)
        end

        G.SetBkMode(hdc, TRANSPARENT)

        for idx = 2, #els do
            local el = els[idx]
            if el.type == "text" and el.frame then
                local a = alphaOf(el.textColor, 1)
                if a > 0.01 then
                    local f   = el.frame
                    local fr  = ffi.new("RECT")
                    fr.left, fr.top    = f.x, f.y
                    fr.right, fr.bottom = f.x + f.w, f.y + f.h

                    local size = el.textSize or 13
                    local face = el.textFont or "Segoe UI"
                    if face == "Helvetica" then face = "Segoe UI" end
                    local font = G.CreateFontW(
                        -math.floor(size * PX_PER_PT + 0.5), 0, 0, 0, FW_NORMAL,
                        0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, toWide(face))
                    local old = G.SelectObject(hdc, font)

                    G.SetTextColor(hdc, blendRef(toRef(el.textColor, DEFAULT_FG), bgRef, a))
                    local txt = tostring(el.text or "")
                    local fmt = (#txt <= 3 or not txt:find("%s")) and FMT_GLYPH or FMT_WRAP
                    if txt:find("\n") then fmt = FMT_WRAP end
                    U.DrawTextW(hdc, toWide(txt), -1, fr, fmt)

                    G.SelectObject(hdc, old)
                    G.DeleteObject(font)
                end
            end
        end

        U.EndPaint(hwnd, ps)
    end
-- END --

-- Shared window procedure (module scope: the GC must never free this cast) --
    -- A Lua error must never unwind through this FFI boundary (Windows calls it from
    -- DispatchMessage; a throw is a hard crash), so each body is pcall-guarded.
    local wndProc = ffi.cast("WNDPROC", function(hwnd, msg, wp, lp)
        local rec = records[keyOf(hwnd)]
        if msg == WM_PAINT then
            if rec then pcall(paint, rec, hwnd)
            else
                -- No record yet: still consume the paint so Windows doesn't loop on it.
                local ps = ffi.new("PAINTSTRUCT"); U.BeginPaint(hwnd, ps); U.EndPaint(hwnd, ps)
            end
            return 0
        elseif msg == WM_MOUSEMOVE then
            if rec and rec.mouseCb then
                pcall(function()
                    if not rec.tracking then
                        rec.tracking = true
                        local tme = ffi.new("MUDSPOON_TME")
                        tme.cbSize = ffi.sizeof("MUDSPOON_TME")
                        tme.dwFlags = TME_LEAVE
                        tme.hwndTrack = hwnd
                        U.TrackMouseEvent(tme)
                        rec.mouseCb(rec.self, "mouseEnter", 1)
                    end
                end)
            end
            return 0
        elseif msg == WM_MOUSELEAVE then
            if rec and rec.mouseCb then
                rec.tracking = false
                pcall(function() rec.mouseCb(rec.self, "mouseExit", 1) end)
            end
            return 0
        elseif msg == WM_LBUTTONDOWN then
            if rec and rec.mouseCb then
                pcall(function()
                    local L = tonumber(ffi.cast("uint32_t", lp))
                    local x = bit.band(L, 0xFFFF);            if x >= 0x8000 then x = x - 0x10000 end
                    local y = bit.band(bit.rshift(L, 16), 0xFFFF); if y >= 0x8000 then y = y - 0x10000 end
                    rec.mouseCb(rec.self, "mouseDown", hitTest(rec, x, y), x, y)
                end)
            end
            return 0
        elseif msg == WM_DESTROY then
            return 0
        end
        return U.DefWindowProcA(hwnd, msg, wp, lp)
    end)
-- END --

-- Register the class once, lazily --
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
            error("hs.canvas: RegisterClassExA failed")
        end
        registered = true
    end
-- END --

local canvas = {}

-- windowLevels / windowBehaviors: numeric tables mudscript indexes + OR-combines --
    -- Values mirror NSWindowLevel / NSWindowCollectionBehavior ordering; on Win32
    -- only the relative magnitude matters (every alert level maps to "topmost").
    canvas.windowLevels = {
        normal = 0, floating = 3, tornOffMenu = 3, modalPanel = 8, utility = 19,
        dock = 20, mainMenu = 24, status = 25, popUpMenu = 101, overlay = 102,
        help = 200, dragging = 500, screenSaver = 1000, assistiveTechHigh = 1500,
        cursor = 2001,
    }
    canvas.windowBehaviors = {
        default = 0, canJoinAllSpaces = 1, moveToActiveSpace = 2, managed = 4,
        transient = 8, stationary = 16, participatesInCycle = 32, ignoresCycle = 64,
        fullScreenPrimary = 128, fullScreenAuxiliary = 256, fullScreenNone = 512,
    }
-- END --

-- Canvas object --
    local Canvas = {}
    Canvas.__index = Canvas

    -- Effective whole-window alpha = animated alpha * the box fill's own alpha, the
    -- best a single layered alpha can do (see FIDELITY NOTES).
    local function applyAlpha(self)
        if self._closed or not self._hwnd then return end
        local a = math.floor(self._alpha * self._fillAlpha * 255 + 0.5)
        if a < 0 then a = 0 elseif a > 255 then a = 255 end
        U.SetLayeredWindowAttributes(self._hwnd, 0, a, LWA_ALPHA)
    end

    local function invalidate(self)
        if not self._closed and self._hwnd then U.InvalidateRect(self._hwnd, nil, true) end
    end

    -- Rounded region matching the current size + the box radius; call after any
    -- create or resize so corners stay rounded.
    local function applyRegion(self)
        if self._closed or not self._hwnd then return end
        local f = self._frame
        U.SetWindowRgn(self._hwnd,
            G.CreateRoundRectRgn(0, 0, f.w + 1, f.h + 1, self._rec.radius, self._rec.radius), true)
    end

    function Canvas:level(_) return self end        -- topmost is applied at show()
    function Canvas:behavior(_) return self end      -- no Spaces concept on Win32

    function Canvas:alpha(a)
        if a == nil then return self._alpha end
        self._alpha = a
        applyAlpha(self)
        return self
    end

    function Canvas:frame(r)
        local f = self._frame
        if r == nil then return { x = f.x, y = f.y, w = f.w, h = f.h } end
        local resized = (r.w and r.w ~= f.w) or (r.h and r.h ~= f.h)
        f.x = r.x or f.x; f.y = r.y or f.y; f.w = r.w or f.w; f.h = r.h or f.h
        if not self._closed and self._hwnd then
            U.MoveWindow(self._hwnd, math.floor(f.x), math.floor(f.y),
                         math.floor(f.w), math.floor(f.h), true)
            if resized then applyRegion(self) end
            invalidate(self)
        end
        return self
    end

    function Canvas:appendElements(...)
        local els = self._rec.elements
        for i = 1, select("#", ...) do
            local el = select(i, ...)
            els[#els + 1] = el
            if el.type == "rectangle" then
                if el.roundedRectRadii and el.roundedRectRadii.xRadius then
                    self._rec.radius = el.roundedRectRadii.xRadius
                end
                self._fillAlpha = alphaOf(el.fillColor, 1)
            end
        end
        applyAlpha(self)
        invalidate(self)
        return self
    end

    -- elementAttribute(i, key, value): mutate one element in place and repaint.
    -- Setter-only (the form mudscript uses); returns self.
    function Canvas:elementAttribute(i, key, value)
        local el = self._rec.elements[i]
        if el then
            el[key] = value
            if i == 1 and key == "fillColor" then
                self._fillAlpha = alphaOf(value, 1); applyAlpha(self)
            end
            if i == 1 and key == "roundedRectRadii" and value and value.xRadius then
                self._rec.radius = value.xRadius; applyRegion(self)
            end
            invalidate(self)
        end
        return self
    end

    function Canvas:mouseCallback(fn)
        self._rec.mouseCb = fn
        return self
    end

    function Canvas:show()
        if self._closed then return self end
        ensureClass()
        local f = self._frame
        if not self._hwnd then
            local hwnd = U.CreateWindowExA(EX_STYLE, classBuf, "", WS_POPUP,
                math.floor(f.x), math.floor(f.y), math.floor(f.w), math.floor(f.h),
                nil, nil, hInst, nil)
            if hwnd == nil then error("hs.canvas: CreateWindowExA failed") end
            self._hwnd    = hwnd
            self._key     = keyOf(hwnd)
            self._rec.self = self
            records[self._key] = self._rec
            applyRegion(self)
        end
        applyAlpha(self)
        U.ShowWindow(self._hwnd, SW_SHOWNOACTIVATE)
        U.SetWindowPos(self._hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_FRONT)
        invalidate(self)
        return self
    end

    -- Legacy geometry getters some Hammerspoon code uses; harmless to keep.
    function Canvas:topLeft(p)
        if p == nil then return { x = self._frame.x, y = self._frame.y } end
        return self:frame({ x = p.x, y = p.y })
    end
    function Canvas:size(s)
        if s == nil then return { w = self._frame.w, h = self._frame.h } end
        return self:frame({ w = s.w, h = s.h })
    end

    function Canvas:hide()
        if not self._closed and self._hwnd then U.ShowWindow(self._hwnd, 0) end  -- SW_HIDE
        return self
    end

    function Canvas:delete()
        if self._closed then return self end
        self._closed = true
        if self._hwnd then
            records[self._key] = nil
            U.DestroyWindow(self._hwnd)
            self._hwnd = nil
        end
        return self
    end
-- END --

-- Constructors --
    function canvas.new(rect)
        rect = rect or {}
        local self = setmetatable({
            _frame     = { x = rect.x or 0, y = rect.y or 0, w = rect.w or 0, h = rect.h or 0 },
            _alpha     = 1,
            _fillAlpha = 1,
            _closed    = false,
            _hwnd      = nil,
            _rec       = { elements = {}, radius = DEFAULT_RADIUS, mouseCb = nil, tracking = false },
        }, Canvas)
        return self
    end

    function canvas.elementCount() return 0 end
-- END --

return canvas
