-- hs.chooser --
    -- A native Win32 fuzzy chooser: a top-most popup with a query line and a
    -- filtered list of choices, painted by hand so it needs no WebView2.
-- END --

local ffi = require("ffi")
local bit = require("bit")

local host = require("hs.foundation")

local U     = host.C.user32
local K     = host.C.kernel32
local G     = host.C.gdi32
local hInst = host.moduleHandle

-- Own FFI surface --
    local DECLARATIONS = {
        "WORD RegisterClassExA(const WNDCLASSEXA*);",
        "HWND CreateWindowExA(DWORD, LPCSTR, LPCSTR, DWORD, int, int, int, int, HWND, HMENU, HINSTANCE, void*);",
        "BOOL ShowWindow(HWND, int);",
        "BOOL DestroyWindow(HWND);",
        "LRESULT DefWindowProcA(HWND, UINT, WPARAM, LPARAM);",
        "BOOL SetWindowPos(HWND, HWND, int, int, int, int, UINT);",
        "HDC BeginPaint(HWND, PAINTSTRUCT*);",
        "BOOL EndPaint(HWND, const PAINTSTRUCT*);",
        "BOOL GetClientRect(HWND, RECT*);",
        "BOOL InvalidateRect(HWND, const RECT*, BOOL);",
        "int FillRect(HDC, const RECT*, HBRUSH);",
        "int DrawTextW(HDC, const unsigned short*, int, RECT*, UINT);",
        "BOOL GetTextExtentPoint32W(HDC, const unsigned short*, int, POINT*);",
        "HBRUSH CreateSolidBrush(DWORD);",
        "BOOL DeleteObject(HGDIOBJ);",
        "int SetBkMode(HDC, int);",
        "DWORD SetTextColor(HDC, DWORD);",
        "HGDIOBJ CreateFontA(int, int, int, int, int, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, LPCSTR);",
        "HGDIOBJ SelectObject(HDC, HGDIOBJ);",
        "HDC CreateCompatibleDC(HDC);",
        "HGDIOBJ CreateCompatibleBitmap(HDC, int, int);",
        "BOOL BitBlt(HDC, int, int, int, int, HDC, int, int, DWORD);",
        "BOOL DeleteDC(HDC);",
        "BOOL SetForegroundWindow(HWND);",
        "HWND SetFocus(HWND);",
        "HWND GetForegroundWindow(void);",
        "DWORD GetWindowThreadProcessId(HWND, DWORD*);",
        "BOOL AttachThreadInput(DWORD, DWORD, BOOL);",
        "DWORD GetCurrentThreadId(void);",
        "int MultiByteToWideChar(UINT, DWORD, const char*, int, unsigned short*, int);",
        "int WideCharToMultiByte(UINT, DWORD, const unsigned short*, int, char*, int, const char*, BOOL*);",
    }

    for _, line in ipairs(DECLARATIONS) do
        pcall(ffi.cdef, line)
    end
-- END --

-- Constants --
    local WS_POPUP        = 0x80000000
    local EX_TOPMOST      = 0x00000008
    local EX_TOOLWINDOW   = 0x00000080
    local EX_STYLE        = bit.bor(EX_TOPMOST, EX_TOOLWINDOW)

    local SW_HIDE         = 0
    local SW_SHOW         = 5

    local SWP_NOACTIVATE  = 0x0010
    local SWP_NOZORDER    = 0x0004

    local WM_DESTROY      = 0x0002
    local WM_ACTIVATE     = 0x0006
    local WM_PAINT        = 0x000F
    local WM_ERASEBKGND   = 0x0014
    local WM_KEYDOWN      = 0x0100
    local WM_CHAR         = 0x0102
    local WM_LBUTTONDOWN  = 0x0201
    local WM_RBUTTONDOWN  = 0x0204
    local WM_MOUSEWHEEL   = 0x020A

    local VK_BACK         = 0x08
    local VK_RETURN       = 0x0D
    local VK_ESCAPE       = 0x1B
    local VK_PRIOR        = 0x21
    local VK_NEXT         = 0x22
    local VK_END          = 0x23
    local VK_HOME         = 0x24
    local VK_UP           = 0x26
    local VK_DOWN         = 0x28

    local DT_VCENTER      = 0x00000004
    local DT_SINGLELINE   = 0x00000020
    local DT_NOPREFIX     = 0x00000800
    local DT_END_ELLIPSIS = 0x00008000
    local DT_TEXT         = bit.bor(DT_VCENTER, DT_SINGLELINE, DT_NOPREFIX, DT_END_ELLIPSIS)

    local SRCCOPY         = 0x00CC0020
    local TRANSPARENT     = 1
    local CP_UTF8         = 65001
    local FW_NORMAL       = 400
    local DEFAULT_CHARSET = 1
    local CLEARTYPE       = 5

    local CLASS           = "HammerspoonChooser"
    local FACE            = "Segoe UI"

    local INPUT_H         = 48
    local ROW_H           = 34
    local ROW_H_SUB       = 50
    local PAD             = 14
    local MIN_WIDTH       = 320
    local TOP_FRACTION    = 0.2

    local SELECT_COLOR    = 0x00D47800
    local DIVIDER_LIGHT   = 0x00DDDDDD
    local DIVIDER_DARK    = 0x00444444
    local PLACEHOLDER     = 0x00999999

    local THEME_LIGHT = {
        bg = 0x00FFFFFF,
        fg = 0x00202020,
        sub = 0x00808080,
    }

    local THEME_DARK = {
        bg = 0x00242424,
        fg = 0x00F0F0F0,
        sub = 0x00A0A0A0,
    }
-- END --

-- Text helpers --
    local function toWide(s)
        s = tostring(s or "")

        local need = K.MultiByteToWideChar(CP_UTF8, 0, s, #s, nil, 0)
        local buf = ffi.new("unsigned short[?]", need + 1)

        K.MultiByteToWideChar(CP_UTF8, 0, s, #s, buf, need)

        return buf, need
    end

    local function acpToUtf8(code)
        if code < 128 then return string.char(code) end

        local one = ffi.new("char[1]", code)
        local wide = ffi.new("unsigned short[2]")

        if K.MultiByteToWideChar(0, 0, one, 1, wide, 2) < 1 then return nil end

        local out = ffi.new("char[8]")
        local n = K.WideCharToMultiByte(CP_UTF8, 0, wide, 1, out, 8, nil, nil)

        return ffi.string(out, n)
    end

    local function dropLastChar(s)
        local i = #s

        while i > 1 and bit.band(s:byte(i), 0xC0) == 0x80 do i = i - 1 end

        return s:sub(1, i - 1)
    end

    local function label(v)
        if v == nil then return "" end

        return tostring(v)
    end

    local function color(c, default)
        if type(c) ~= "table" then return default end

        local function chan(v) return math.floor(math.max(0, math.min(1, v or 0)) * 255 + 0.5) end

        return chan(c.red) + chan(c.green) * 256 + chan(c.blue) * 65536
    end
-- END --

-- Screen metrics --
    local function scale()
        local ok, v = pcall(function() return require("hs.dpiscale").get() end)

        return ok and v or 1
    end

    local function screenFrame()
        local ok, f = pcall(function() return require("hs.screen").mainScreen():frame() end)

        if ok and f then return f end

        return {
            x = 0,
            y = 0,
            w = 1920,
            h = 1080,
        }
    end
-- END --

-- Fonts --
    local fonts = {}

    local function fontFor(size)
        local key = size

        if not fonts[key] then
            fonts[key] = G.CreateFontA(-size, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE, 0, FACE)
        end

        return fonts[key]
    end
-- END --

local chooser = {}

local Chooser = {}

Chooser.__index = Chooser

local byWindow = {}

local function keyOf(hwnd)
    return tonumber(ffi.cast("intptr_t", hwnd))
end

local function fire(fn, ...)
    if type(fn) ~= "function" then return end

    local ok, err = pcall(fn, ...)

    if not ok then print("hs.chooser: callback error: " .. tostring(err)) end
end

-- Filtering --
    local function splitWords(q)
        local words = {}

        for w in q:lower():gmatch("%S+") do words[#words + 1] = w end

        return words
    end

    function Chooser:_refilter()
        local all = self._source

        if type(all) ~= "table" then all = {} end

        if self._queryFn then
            self._list = all
        else
            local words = splitWords(self._query)
            local out = {}

            for _, c in ipairs(all) do
                local hay = label(c.text):lower()

                if self._searchSub then hay = hay .. " " .. label(c.subText):lower() end

                local ok = true

                for _, w in ipairs(words) do
                    if not hay:find(w, 1, true) then
                        ok = false

                        break
                    end
                end

                if ok then out[#out + 1] = c end
            end

            self._list = out
        end

        self._sel = (#self._list > 0) and 1 or 0
        self._top = 0
    end

    function Chooser:_hasSub()
        for _, c in ipairs(self._list) do
            if c.subText ~= nil and label(c.subText) ~= "" then return true end
        end

        return false
    end
-- END --

-- Layout --
    function Chooser:_metrics()
        local s = scale()
        local f = screenFrame()
        local rowH = math.floor((self:_hasSub() and ROW_H_SUB or ROW_H) * s)
        local shown = math.max(1, math.min(self._rows, #self._list))
        local fullW = f.w * s
        local w = math.max(math.floor(MIN_WIDTH * s), math.floor(fullW * self._width / 100))
        local inputH = math.floor(INPUT_H * s)
        local h = inputH + (#self._list > 0 and shown * rowH or 0)

        return {
            s = s,
            frame = f,
            rowH = rowH,
            shown = shown,
            w = w,
            h = h,
            inputH = inputH,
            pad = math.floor(PAD * s),
        }
    end

    function Chooser:_keepVisible()
        local shown = math.max(1, math.min(self._rows, #self._list))

        if self._sel - 1 < self._top then self._top = self._sel - 1 end

        if self._sel > self._top + shown then self._top = self._sel - shown end

        if self._top < 0 then self._top = 0 end
    end

    function Chooser:_relayout()
        if not self._hwnd then return end

        local m = self:_metrics()

        self._m = m

        U.SetWindowPos(self._hwnd, nil, self._x or 0, self._y or 0, m.w, m.h, bit.bor(SWP_NOACTIVATE, SWP_NOZORDER))
        U.InvalidateRect(self._hwnd, nil, 0)
    end

    function Chooser:_changed()
        if self._queryFn then
            fire(self._queryFn, self._query)
        end

        self:_refilter()
        self:_relayout()
    end
-- END --

-- Painting --
    local function drawText(hdc, s, rect, flags)
        if s == "" then return end

        local buf, n = toWide(s)

        U.DrawTextW(hdc, buf, n, rect, flags)
    end

    local function fillRect(hdc, l, t, r, b, c)
        local rc = ffi.new("RECT", l, t, r, b)
        local brush = G.CreateSolidBrush(c)

        U.FillRect(hdc, rc, brush)
        G.DeleteObject(brush)
    end

    function Chooser:_theme()
        local base = self._dark and THEME_DARK or THEME_LIGHT

        return {
            bg = base.bg,
            fg = self._fg or base.fg,
            sub = self._subColor or base.sub,
            divider = self._dark and DIVIDER_DARK or DIVIDER_LIGHT,
        }
    end

    function Chooser:_paint(hdc)
        local m = self._m or self:_metrics()
        local t = self:_theme()
        local s = m.s
        local mainFont = fontFor(math.floor(18 * s))
        local subFont = fontFor(math.floor(13 * s))

        fillRect(hdc, 0, 0, m.w, m.h, t.bg)

        G.SetBkMode(hdc, TRANSPARENT)

        local old = G.SelectObject(hdc, mainFont)

        local qRect = ffi.new("RECT", m.pad, 0, m.w - m.pad, m.inputH)

        if self._query == "" then
            G.SetTextColor(hdc, PLACEHOLDER)
            drawText(hdc, self._placeholder, qRect, DT_TEXT)
        else
            G.SetTextColor(hdc, t.fg)
            drawText(hdc, self._query, qRect, DT_TEXT)
        end

        local qBuf, qLen = toWide(self._query)
        local ext = ffi.new("POINT")

        G.SetTextColor(hdc, t.fg)
        U.GetTextExtentPoint32W(hdc, qBuf, qLen, ext)

        local caretX = math.min(m.w - m.pad, m.pad + ext.x + 1)

        fillRect(hdc, caretX, math.floor(m.inputH * 0.25), caretX + math.max(1, math.floor(s)), math.floor(m.inputH * 0.75), t.fg)

        if #self._list > 0 then
            fillRect(hdc, 0, m.inputH - 1, m.w, m.inputH, t.divider)
        end

        for i = 1, m.shown do
            local idx = self._top + i
            local c = self._list[idx]

            if not c then break end

            local y = m.inputH + (i - 1) * m.rowH
            local selected = idx == self._sel
            local fg = selected and 0x00FFFFFF or t.fg
            local sub = selected and 0x00F0E0D0 or t.sub
            local text = label(c.text)
            local subText = label(c.subText)

            if selected then fillRect(hdc, 0, y, m.w, y + m.rowH, SELECT_COLOR) end

            G.SelectObject(hdc, mainFont)
            G.SetTextColor(hdc, fg)

            if subText ~= "" then
                local half = math.floor(m.rowH * 0.55)

                drawText(hdc, text, ffi.new("RECT", m.pad, y, m.w - m.pad, y + half), DT_TEXT)

                G.SelectObject(hdc, subFont)
                G.SetTextColor(hdc, sub)
                drawText(hdc, subText, ffi.new("RECT", m.pad, y + half - math.floor(2 * s), m.w - m.pad, y + m.rowH), DT_TEXT)
            else
                drawText(hdc, text, ffi.new("RECT", m.pad, y, m.w - m.pad, y + m.rowH), DT_TEXT)
            end
        end

        G.SelectObject(hdc, old)
    end

    function Chooser:_paintBuffered(hwnd)
        local ps = ffi.new("PAINTSTRUCT")
        local hdc = U.BeginPaint(hwnd, ps)
        local m = self._m or self:_metrics()
        local mem = G.CreateCompatibleDC(hdc)
        local bmp = G.CreateCompatibleBitmap(hdc, m.w, m.h)
        local oldBmp = G.SelectObject(mem, bmp)

        self:_paint(mem)

        G.BitBlt(hdc, 0, 0, m.w, m.h, mem, 0, 0, SRCCOPY)
        G.SelectObject(mem, oldBmp)
        G.DeleteObject(bmp)
        G.DeleteDC(mem)

        U.EndPaint(hwnd, ps)
    end
-- END --

-- Choosing --
    function Chooser:_complete(choice)
        host.schedule(0, function()
            fire(self._fn, choice)
        end)
    end

    function Chooser:_choose(idx)
        local choice = self._list[idx]

        if not choice then
            if self._defaultForQuery and self._query ~= "" and #self._list == 0 then
                self:hide()
                self:_complete({ text = self._query })
            end

            return
        end

        if choice.valid == false then
            fire(self._invalidFn)

            return
        end

        self:hide()
        self:_complete(choice)
    end

    function Chooser:_move(delta)
        if #self._list == 0 then return end

        local n = self._sel + delta

        if n < 1 then n = 1 end

        if n > #self._list then n = #self._list end

        self._sel = n

        self:_keepVisible()
        U.InvalidateRect(self._hwnd, nil, 0)
    end

    function Chooser:_rowAt(y)
        local m = self._m

        if not m or y < m.inputH then return nil end

        local i = math.floor((y - m.inputH) / m.rowH) + 1

        if i < 1 or i > m.shown then return nil end

        local idx = self._top + i

        if idx > #self._list then return nil end

        return idx
    end
-- END --

-- Window procedure --
    local function loWord(v) return bit.band(tonumber(v), 0xFFFF) end

    local function signedHiWord(v)
        local h = bit.band(bit.rshift(tonumber(v), 16), 0xFFFF)

        if h >= 0x8000 then h = h - 0x10000 end

        return h
    end

    local function handle(self, hwnd, msg, wp, lp)
        if msg == WM_PAINT then
            self:_paintBuffered(hwnd)

            return 0
        elseif msg == WM_ERASEBKGND then
            return 1
        elseif msg == WM_ACTIVATE then
            if loWord(wp) == 0 and self._visible then self:hide() end

            return 0
        elseif msg == WM_KEYDOWN then
            local vk = tonumber(wp)

            if vk == VK_ESCAPE then
                self:hide()
                self:_complete(nil)
            elseif vk == VK_RETURN then
                self:_choose(self._sel)
            elseif vk == VK_UP then
                self:_move(-1)
            elseif vk == VK_DOWN then
                self:_move(1)
            elseif vk == VK_PRIOR then
                self:_move(-self._rows)
            elseif vk == VK_NEXT then
                self:_move(self._rows)
            elseif vk == VK_HOME then
                self:_move(-#self._list)
            elseif vk == VK_END then
                self:_move(#self._list)
            end

            return 0
        elseif msg == WM_CHAR then
            local code = tonumber(wp)

            if code == VK_BACK then
                if self._query ~= "" then
                    self._query = dropLastChar(self._query)

                    self:_changed()
                end
            elseif code >= 32 and code ~= 127 then
                local ch = acpToUtf8(code)

                if ch then
                    self._query = self._query .. ch

                    self:_changed()
                end
            end

            return 0
        elseif msg == WM_LBUTTONDOWN then
            local y = signedHiWord(lp)
            local idx = self:_rowAt(y)

            if idx then self:_choose(idx) end

            return 0
        elseif msg == WM_RBUTTONDOWN then
            local idx = self:_rowAt(signedHiWord(lp))

            if idx then fire(self._rightClickFn, idx) end

            return 0
        elseif msg == WM_MOUSEWHEEL then
            local step = signedHiWord(wp) > 0 and -1 or 1

            self._top = math.max(0, math.min(math.max(0, #self._list - self._rows), self._top + step))

            U.InvalidateRect(hwnd, nil, 0)

            return 0
        end

        return nil
    end

    local function wndProcFn(hwnd, msg, wp, lp)
        local self = byWindow[keyOf(hwnd)]
        local result

        if self then
            local ok, r = pcall(handle, self, hwnd, msg, wp, lp)

            if ok then
                result = r
            else
                print("hs.chooser: window error: " .. tostring(r))
            end
        end

        if result ~= nil then return result end

        return U.DefWindowProcA(hwnd, msg, wp, lp)
    end

    jit.off(wndProcFn, true)

    local wndProc = ffi.cast("WNDPROC", wndProcFn)

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

        if U.RegisterClassExA(wc) == 0 then error("hs.chooser: RegisterClassExA failed") end

        registered = true
    end
-- END --

-- Showing and hiding --
    function Chooser:_ensureWindow()
        if self._hwnd then return end

        ensureClass()

        local hwnd = U.CreateWindowExA(EX_STYLE, classBuf, "", WS_POPUP, 0, 0, 10, 10, nil, nil, hInst, nil)

        if hwnd == nil then error("hs.chooser: CreateWindowExA failed") end

        self._hwnd = hwnd

        byWindow[keyOf(hwnd)] = self
    end

    local function takeForeground(hwnd)
        local fg = U.GetForegroundWindow()
        local ours = K.GetCurrentThreadId()
        local theirs = (fg ~= nil) and U.GetWindowThreadProcessId(fg, nil) or 0
        local attached = theirs ~= 0 and theirs ~= ours

        if attached then U.AttachThreadInput(theirs, ours, 1) end

        U.SetForegroundWindow(hwnd)
        U.SetFocus(hwnd)

        if attached then U.AttachThreadInput(theirs, ours, 0) end
    end

    function Chooser:show(topLeft)
        if self._visible then return self end

        if self._refreshFn then fire(self._refreshFn) end

        self:_ensureWindow()
        self:_refilter()

        local m = self:_metrics()
        local f = m.frame

        self._m = m

        if type(topLeft) == "table" and topLeft.x and topLeft.y then
            self._x = math.floor(topLeft.x * m.s)
            self._y = math.floor(topLeft.y * m.s)
        else
            self._x = math.floor(f.x * m.s + (f.w * m.s - m.w) / 2)
            self._y = math.floor(f.y * m.s + f.h * m.s * TOP_FRACTION)
        end

        U.SetWindowPos(self._hwnd, nil, self._x, self._y, m.w, m.h, bit.bor(SWP_NOACTIVATE, SWP_NOZORDER))

        self._visible = true

        U.ShowWindow(self._hwnd, SW_SHOW)
        takeForeground(self._hwnd)
        U.InvalidateRect(self._hwnd, nil, 0)

        fire(self._showFn)

        return self
    end

    function Chooser:hide()
        if not self._visible then return self end

        self._visible = false

        if self._hwnd then U.ShowWindow(self._hwnd, SW_HIDE) end

        fire(self._hideFn)

        return self
    end

    function Chooser:isVisible()
        return self._visible == true
    end

    function Chooser:delete()
        if self._visible then self:hide() end

        if self._hwnd then
            byWindow[keyOf(self._hwnd)] = nil

            U.DestroyWindow(self._hwnd)

            self._hwnd = nil
        end

        self._deleted = true
    end
-- END --

-- Data and state accessors --
    function Chooser:choices(c)
        if c == nil then return self._choicesArg end

        self._choicesArg = c

        local value = c

        if type(c) == "function" then
            local ok, r = pcall(c)

            value = ok and r or {}
        end

        self._source = value

        self:_refilter()
        self:_relayout()

        return self
    end

    function Chooser:query(q)
        if q == nil then return self._query end

        self._query = tostring(q)

        self:_changed()

        return self
    end

    function Chooser:selectedRow(n)
        if n == nil then return self._sel end

        n = math.floor(tonumber(n) or 0)

        if n >= 1 and n <= #self._list then
            self._sel = n

            self:_keepVisible()

            if self._hwnd then U.InvalidateRect(self._hwnd, nil, 0) end
        end

        return self
    end

    function Chooser:selectedRowContents(n)
        return self._list[n or self._sel]
    end

    function Chooser:select(n)
        if n ~= nil then return self:selectedRow(n) end

        self:_choose(self._sel)

        return self
    end

    function Chooser:refreshChoicesCallback(fn)
        if fn == nil and not self._refreshSet then return self._refreshFn end

        self._refreshFn = fn
        self._refreshSet = true

        return self
    end

    function Chooser:attachedToolbar()
        return nil
    end
-- END --

-- Callback accessors --
    local function callbackAccessor(field)
        return function(self, fn)
            if fn == nil then return self[field] end

            self[field] = fn

            return self
        end
    end

    Chooser.queryChangedCallback = callbackAccessor("_queryFn")
    Chooser.showCallback         = callbackAccessor("_showFn")
    Chooser.hideCallback         = callbackAccessor("_hideFn")
    Chooser.invalidCallback      = callbackAccessor("_invalidFn")
    Chooser.rightClickCallback   = callbackAccessor("_rightClickFn")
-- END --

-- Appearance accessors --
    local function valueAccessor(field, relayout)
        return function(self, v)
            if v == nil then return self[field] end

            self[field] = v

            if relayout then
                self:_refilter()
                self:_relayout()
            elseif self._hwnd then
                U.InvalidateRect(self._hwnd, nil, 0)
            end

            return self
        end
    end

    Chooser.placeholderText       = valueAccessor("_placeholder")
    Chooser.searchSubText         = valueAccessor("_searchSub", true)
    Chooser.rows                  = valueAccessor("_rows", true)
    Chooser.width                 = valueAccessor("_width", true)
    Chooser.bgDark                = valueAccessor("_dark")
    Chooser.enableDefaultForQuery = valueAccessor("_defaultForQuery")

    function Chooser:fgColor(c)
        if c == nil then return self._fgTable end

        self._fgTable = c
        self._fg = color(c)

        if self._hwnd then U.InvalidateRect(self._hwnd, nil, 0) end

        return self
    end

    function Chooser:subTextColor(c)
        if c == nil then return self._subTable end

        self._subTable = c
        self._subColor = color(c)

        if self._hwnd then U.InvalidateRect(self._hwnd, nil, 0) end

        return self
    end
-- END --

-- hs.chooser.new(completionFn) -> chooser --
    function chooser.new(fn)
        return setmetatable({
            _fn = fn,
            _query = "",
            _source = {},
            _list = {},
            _sel = 0,
            _top = 0,
            _rows = 10,
            _width = 40,
            _placeholder = "",
            _searchSub = false,
            _dark = false,
            _defaultForQuery = false,
            _visible = false,
        }, Chooser)
    end
-- END --

return chooser
