-- hs.canvas  (Win32 per-pixel-alpha backend, general element set) --
    -- Hammerspoon's hs.canvas is a full vector surface. This is a borderless, layered,
    -- top-most popup whose pixels come from UpdateLayeredWindow -- a 32bpp premultiplied
    -- bitmap drawn ANTI-ALIASED with GDI+. Smooth rounded corners, genuinely transparent
    -- corners (no clip-to-background white), and true per-pixel alpha (fill translucency
    -- and glyph fades are real, not faked).
    --
    -- The load-bearing consumer is ms_alert (a rounded translucent rectangle + centred
    -- text, rig-verified), but the element set is general -- rectangle/oval/segments/
    -- text/image -- so plugin UIs can draw arbitrary scenes, not just toasts.
    --
    -- Contract mudscript relies on (see mac/lib/ms_alert.lua):
    --   hs.canvas.windowLevels / .windowBehaviors  -- numeric tables read at load
    --   hs.canvas.new({x,y,w,h}) -> canvas
    --     :level(n) :behavior(n) :alpha([a])   -- a in 0..1 (whole-window fade)
    --     :frame([{x,y,w,h}])                   -- get (copy) / set (moves+resizes)
    --     :appendElements(el, ...)              -- rectangle | text specs
    --     :elementAttribute(i, key, value)      -- mutate one element, re-render
    --     :mouseCallback(fn)  -- fn(canvas, msg, elemId, x, y); msg =
    --                            "mouseEnter"|"mouseExit"|"mouseDown"
    --     :show() :delete()   -- delete is idempotent
    --
    -- Element specs honoured (all share action="fill"|"stroke"|"strokeAndFill", default
    -- strokeAndFill, plus fillColor/strokeColor/strokeWidth where they apply):
    --   rectangle: roundedRectRadii.xRadius; frame OR frame-less (fills the window)
    --   oval:      inscribed in frame (aliases: circle, ellipse)
    --   segments:  coordinates {{x,y},...}; closed=true -> fillable polygon (alias: line)
    --   text:      text, textFont, textSize, textColor, textAlignment
    --              (left|center|right|natural|justified), frame{x,y,w,h}
    --   image:     el.image = a file-path string (or a table with .path); frame or full
    -- Colours are Hammerspoon tables {red,green,blue,alpha} in 0..1.
    --
    -- RENDER MODEL: render() (re)builds a top-down 32bpp DIB the size of the window,
    -- draws the elements into it with GDI+ (premultiplied PARGB, anti-aliased), then
    -- pushes it with UpdateLayeredWindow. The whole-window fade (:alpha) is the ULW
    -- BLENDFUNCTION's SourceConstantAlpha -- so a fade step just re-pushes the same DIB
    -- with a new constant alpha, no re-render. A position-only :frame move likewise
    -- re-pushes without redrawing; a size change re-renders.
    --
    -- THREADING: every entry point touches the window on the calling thread, which must
    -- be the runloop/pump thread. mudscript drives canvases only from timer callbacks.
    --
    -- DPI: all incoming coords + font sizes are LOGICAL (mac-like points); logi() scales
    -- them to physical device pixels at the window boundary. See [[hs.dpiscale]].
    --
    -- CDEF OWNERSHIP: foundation owns shared typedefs; this cdefs ONLY prototypes/structs
    -- nothing else declares. UTF-8 -> UTF-16 is pure-Lua (no MultiByteToWideChar, which
    -- webview owns conditionally), so canvas is independent of whether webview loaded.
-- END --

local ffi = require("ffi")
local bit = require("bit")

local host     = require("hs.foundation")
local timer    = require("hs.timer")
local dpiscale = require("hs.dpiscale")
local U        = host.C.user32
local G        = host.C.gdi32
local hInst    = host.moduleHandle

-- gdiplus is standard on Windows, but guard the load so a missing DLL degrades to a
-- (blank) no-op canvas rather than crashing boot -- canvas is required at startup.
local okGP, GP = pcall(ffi.load, "gdiplus")
if not okGP then GP = nil end

-- Logical (mac-point) -> physical device pixels; unscale maps a physical pointer coord
-- back to logical for hit testing. Scale is 1.0 when the process is DPI-unaware.
local function logi(v)    return math.floor(v * dpiscale.get() + 0.5) end
local function unscale(v) return v / dpiscale.get() end

-- Own FFI surface (functions + structs nothing else declares) --
    ffi.cdef[[
/* --- window + layered blit (user32) --- */
BOOL    UpdateLayeredWindow(HWND, HDC, POINT*, void* /*SIZE*/, HDC, POINT*, DWORD, void* /*BLENDFUNCTION*/, DWORD);
HCURSOR LoadCursorA(HINSTANCE, LPCSTR);

/* --- memory DC + DIB (gdi32) --- */
HDC     CreateCompatibleDC(HDC);
BOOL    DeleteDC(HDC);
void*   CreateDIBSection(HDC, const void*, unsigned int, void**, HANDLE, DWORD);
HGDIOBJ SelectObject(HDC, HGDIOBJ);

/* --- mouse tracking (user32) --- */
typedef struct { DWORD cbSize; DWORD dwFlags; HWND hwndTrack; DWORD dwHoverTime; } MUDSPOON_TME;
BOOL    TrackMouseEvent(MUDSPOON_TME*);

/* --- structs --- */
typedef struct { LONG cx; LONG cy; } SIZE;
typedef struct { BYTE BlendOp; BYTE BlendFlags; BYTE SourceConstantAlpha; BYTE AlphaFormat; } BLENDFUNCTION;
typedef struct {
    DWORD biSize; LONG biWidth; LONG biHeight; WORD biPlanes; WORD biBitCount;
    DWORD biCompression; DWORD biSizeImage; LONG biXPelsPerMeter; LONG biYPelsPerMeter;
    DWORD biClrUsed; DWORD biClrImportant;
} BITMAPINFOHEADER;
typedef struct { float X; float Y; float Width; float Height; } GpRectF;
typedef struct { float X; float Y; } GpPointF;
typedef struct { unsigned int GdiplusVersion; void* DebugEventCallback; int Suppress1; int Suppress2; } GpStartupInput;

/* --- GDI+ flat API (gdiplus) --- */
int GdiplusStartup(ULONG_PTR*, const GpStartupInput*, void*);
int GdipCreateBitmapFromScan0(int, int, int, int, unsigned char*, void**);
int GdipGetImageGraphicsContext(void*, void**);
int GdipDisposeImage(void*);
int GdipDeleteGraphics(void*);
int GdipSetSmoothingMode(void*, int);
int GdipSetTextRenderingHint(void*, int);
int GdipGraphicsClear(void*, unsigned int);
int GdipCreatePath(int, void**);
int GdipDeletePath(void*);
int GdipAddPathArc(void*, float, float, float, float, float, float);
int GdipAddPathEllipse(void*, float, float, float, float);
int GdipAddPathLine2(void*, const GpPointF*, int);
int GdipClosePathFigure(void*);
int GdipCreateSolidFill(unsigned int, void**);
int GdipDeleteBrush(void*);
int GdipFillPath(void*, void*, void*);
int GdipCreatePen1(unsigned int, float, int, void**);
int GdipDeletePen(void*);
int GdipDrawPath(void*, void*, void*);
int GdipCreateFontFamilyFromName(const unsigned short*, void*, void**);
int GdipGetGenericFontFamilySansSerif(void**);
int GdipDeleteFontFamily(void*);
int GdipCreateFont(void*, float, int, int, void**);
int GdipDeleteFont(void*);
int GdipCreateStringFormat(int, int, void**);
int GdipDeleteStringFormat(void*);
int GdipSetStringFormatAlign(void*, int);
int GdipSetStringFormatLineAlign(void*, int);
int GdipDrawString(void*, const unsigned short*, int, void*, const GpRectF*, void*, void*);
int GdipLoadImageFromFile(const unsigned short*, void**);
int GdipDrawImageRect(void*, void*, float, float, float, float);
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

    local HWND_TOPMOST      = ffi.cast("HWND", ffi.cast("intptr_t", -1))
    local SWP_NOSIZE        = 0x0001
    local SWP_NOMOVE        = 0x0002
    local SWP_NOACTIVATE    = 0x0010
    local SWP_FRONT         = bit.bor(SWP_NOSIZE, SWP_NOMOVE, SWP_NOACTIVATE)

    local WM_DESTROY        = 0x0002
    local WM_ERASEBKGND     = 0x0014
    local WM_PAINT          = 0x000F
    local WM_MOUSEMOVE      = 0x0200
    local WM_LBUTTONDOWN    = 0x0201
    local WM_MOUSELEAVE     = 0x02A3
    local TME_LEAVE         = 0x00000002

    local FRONT_MS          = 0.1   -- keep-on-top re-front cadence (see startKeepFront)

    -- UpdateLayeredWindow
    local ULW_ALPHA         = 0x02
    local AC_SRC_OVER       = 0x00
    local AC_SRC_ALPHA      = 0x01
    local BI_RGB            = 0
    local DIB_RGB_COLORS    = 0

    -- GDI+ enums
    local SMOOTHING_ANTIALIAS   = 4
    local TEXT_ANTIALIAS        = 4     -- grayscale AA -> correct alpha on transparency
    local UNIT_PIXEL            = 2
    local FILLMODE_ALTERNATE    = 0
    local FONTSTYLE_REGULAR     = 0
    local STR_ALIGN_NEAR        = 0   -- left / top
    local STR_ALIGN_CENTER      = 1
    local STR_ALIGN_FAR         = 2   -- right / bottom
    -- Hammerspoon textAlignment string -> GDI+ StringAlignment (horizontal).
    local TEXT_ALIGN = {
        left = STR_ALIGN_NEAR, natural = STR_ALIGN_NEAR, justified = STR_ALIGN_NEAR,
        center = STR_ALIGN_CENTER, right = STR_ALIGN_FAR,
    }
    local PF_32BPP_PARGB        = 0x000E200B   -- PixelFormat32bppPARGB (premultiplied)

    local DEFAULT_RADIUS    = 20
    local DEFAULT_BG_ARGB   = 0xFF1C1F24   -- deepslate, opaque
    local DEFAULT_FG_ARGB   = 0xFFE8E8E8

    local CLASS             = "MudspoonCanvas"
-- END --

-- Colour helpers: Hammerspoon {red,green,blue,alpha} 0..1 -> GDI+ ARGB 0xAARRGGBB --
    local function toArgb(c, fallback)
        if type(c) ~= "table" or c.red == nil then return fallback end
        local a = math.floor((c.alpha or 1) * 255 + 0.5)
        local r = math.floor((c.red   or 0) * 255 + 0.5)
        local g = math.floor((c.green or 0) * 255 + 0.5)
        local b = math.floor((c.blue  or 0) * 255 + 0.5)
        return a * 0x1000000 + r * 0x10000 + g * 0x100 + b
    end
-- END --

-- UTF-8 -> UTF-16 (pure Lua; no MultiByteToWideChar dependency) --
    -- Returns an ffi uint16[?] buffer (NUL-terminated). Malformed bytes are skipped.
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

-- GDI+ startup (once, for the process life) --
    local gdiplusOk = false
    do
        local token = ffi.new("ULONG_PTR[1]")
        local input = ffi.new("GpStartupInput")
        input.GdiplusVersion = 1
        gdiplusOk = pcall(function() return GP.GdiplusStartup(token, input, nil) == 0 end) and true
        _G.__mudspoon_gdiplusToken = token   -- anchor; never shut down (process exit frees)
    end
-- END --

-- Per-window records for the shared WndProc, keyed by HWND-as-integer --
    local records = {}
    local renderErrLogged = false

    local function keyOf(hwnd) return tonumber(ffi.cast("intptr_t", hwnd)) end

    -- Hit-test: the top-most element (highest index) whose frame contains (x,y),
    -- else 1 (the rectangle -- whole client). Coords are LOGICAL.
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

-- Shared window procedure (module scope: the GC must never free this cast) --
    -- No custom WM_PAINT drawing -- the layered content comes from UpdateLayeredWindow.
    -- WM_PAINT is just validated so Windows stops re-posting it; WM_ERASEBKGND is
    -- claimed so the window never blanks between frames. Mouse messages fire the cb.
    local wndProc = ffi.cast("WNDPROC", function(hwnd, msg, wp, lp)
        local rec = records[keyOf(hwnd)]
        if msg == WM_PAINT then
            local ps = ffi.new("PAINTSTRUCT"); U.BeginPaint(hwnd, ps); U.EndPaint(hwnd, ps)
            return 0
        elseif msg == WM_ERASEBKGND then
            return 1
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
                    local x = bit.band(L, 0xFFFF);                  if x >= 0x8000 then x = x - 0x10000 end
                    local y = bit.band(bit.rshift(L, 16), 0xFFFF);  if y >= 0x8000 then y = y - 0x10000 end
                    x, y = unscale(x), unscale(y)   -- physical client -> logical for hit test
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
        -- Standard arrow cursor (else Windows keeps the last/app-starting cursor over us).
        wc.hCursor       = U.LoadCursorA(nil, ffi.cast("LPCSTR", 32512))  -- IDC_ARROW
        if U.RegisterClassExA(wc) == 0 then
            error("hs.canvas: RegisterClassExA failed")
        end
        registered = true
    end
-- END --

-- GDI+ scene drawing into a graphics context (physical pixels) --
    -- Build the rounded-rect path once (fill + stroke share it), inset by the stroke so
    -- the border stays fully inside the bitmap; then draw each text element.
    local function addRoundRect(path, x, y, w, h, r)
        r = math.max(0, math.min(r, math.min(w, h) / 2))
        local d = r * 2
        if r <= 0 then
            -- Degenerate: a plain rectangle via four zero-radius corners.
            GP.GdipAddPathArc(path, x,       y,       0, 0, 180, 90)
            GP.GdipAddPathArc(path, x + w,   y,       0, 0, 270, 90)
            GP.GdipAddPathArc(path, x + w,   y + h,   0, 0,   0, 90)
            GP.GdipAddPathArc(path, x,       y + h,   0, 0,  90, 90)
        else
            GP.GdipAddPathArc(path, x,           y,           d, d, 180, 90)
            GP.GdipAddPathArc(path, x + w - d,   y,           d, d, 270, 90)
            GP.GdipAddPathArc(path, x + w - d,   y + h - d,   d, d,   0, 90)
            GP.GdipAddPathArc(path, x,           y + h - d,   d, d,  90, 90)
        end
        GP.GdipClosePathFigure(path)
    end

    -- Physical-pixel frame for an element; a frame-less element covers the window.
    local function physFrame(el, phW, phH)
        local f = el.frame
        if not f then return 0, 0, phW, phH end
        return logi(f.x), logi(f.y), logi(f.w), logi(f.h)
    end

    -- Fill and/or stroke a prebuilt path per the element's action. Hammerspoon's
    -- default action is "strokeAndFill"; a colour is only drawn when it is present.
    local function fillStrokePath(gfx, el, path)
        local action = el.action or "strokeAndFill"
        if (action == "fill" or action == "strokeAndFill") and el.fillColor then
            local brush = ffi.new("void*[1]")
            GP.GdipCreateSolidFill(toArgb(el.fillColor, DEFAULT_BG_ARGB), brush)
            GP.GdipFillPath(gfx, brush[0], path)
            GP.GdipDeleteBrush(brush[0])
        end
        if (action == "stroke" or action == "strokeAndFill") and el.strokeColor then
            local sw  = math.max(1, logi(el.strokeWidth or 1))
            local pen = ffi.new("void*[1]")
            GP.GdipCreatePen1(toArgb(el.strokeColor, DEFAULT_FG_ARGB), sw, UNIT_PIXEL, pen)
            GP.GdipDrawPath(gfx, pen[0], path)
            GP.GdipDeletePen(pen[0])
        end
    end

    -- rectangle (rounded via roundedRectRadii.xRadius). A frame-less rectangle fills
    -- the window, inset by half its stroke so the border stays inside the bitmap --
    -- this is the ms_alert background path, byte-for-byte the prior behaviour.
    local function drawRect(gfx, el, phW, phH, rec)
        local sw = el.strokeColor and math.max(1, logi(el.strokeWidth or 1)) or 0
        local x, y, w, h, radius
        if not el.frame then
            local inset = math.max(1, sw / 2)
            x, y, w, h = inset, inset, phW - 2 * inset, phH - 2 * inset
            local r = (el.roundedRectRadii and el.roundedRectRadii.xRadius) or rec.radius
            radius = logi(r) - inset
        else
            x, y, w, h = physFrame(el, phW, phH)
            radius = (el.roundedRectRadii and el.roundedRectRadii.xRadius)
                     and logi(el.roundedRectRadii.xRadius) or 0
        end
        local path = ffi.new("void*[1]")
        GP.GdipCreatePath(FILLMODE_ALTERNATE, path)
        addRoundRect(path[0], x, y, w, h, radius)
        fillStrokePath(gfx, el, path[0])
        GP.GdipDeletePath(path[0])
    end

    -- oval / circle: an ellipse inscribed in the element frame.
    local function drawOval(gfx, el, phW, phH)
        local x, y, w, h = physFrame(el, phW, phH)
        local path = ffi.new("void*[1]")
        GP.GdipCreatePath(FILLMODE_ALTERNATE, path)
        GP.GdipAddPathEllipse(path[0], x, y, w, h)
        fillStrokePath(gfx, el, path[0])
        GP.GdipDeletePath(path[0])
    end

    -- segments: a polyline through coordinates {{x,y},...} (logical). closed=true makes
    -- it a fillable polygon; otherwise it is stroked open.
    local function drawSegments(gfx, el)
        local pts = el.coordinates
        if type(pts) ~= "table" or #pts < 2 then return end
        local arr = ffi.new("GpPointF[?]", #pts)
        for i = 1, #pts do
            arr[i - 1].X = logi(pts[i].x or 0)
            arr[i - 1].Y = logi(pts[i].y or 0)
        end
        local path = ffi.new("void*[1]")
        GP.GdipCreatePath(FILLMODE_ALTERNATE, path)
        GP.GdipAddPathLine2(path[0], arr, #pts)
        if el.closed then GP.GdipClosePathFigure(path[0]) end
        fillStrokePath(gfx, el, path[0])
        GP.GdipDeletePath(path[0])
    end

    -- text: one string, horizontally aligned per textAlignment, vertically centred in
    -- its frame. mudspoon keeps the vertical centre (Hammerspoon anchors text at the
    -- top) so the rig-verified alert layout is preserved; alert frames are line-tight so
    -- the difference is nil there, and centred-in-box is the sane default for plugin UIs.
    local function drawText(gfx, el)
        if not el.frame or (el.text or "") == "" then return end
        local argb = toArgb(el.textColor, DEFAULT_FG_ARGB)
        if math.floor(argb / 0x1000000) <= 1 then return end   -- alpha ~0: nothing to draw

        local face = el.textFont or "Segoe UI"
        if face == "Helvetica" then face = "Segoe UI" end
        local family = ffi.new("void*[1]")
        if GP.GdipCreateFontFamilyFromName(toWide(face), nil, family) ~= 0 then
            GP.GdipGetGenericFontFamilySansSerif(family)
        end
        local font = ffi.new("void*[1]")
        GP.GdipCreateFont(family[0], logi(el.textSize or 13), FONTSTYLE_REGULAR, UNIT_PIXEL, font)

        local fmt = ffi.new("void*[1]")
        GP.GdipCreateStringFormat(0, 0, fmt)
        GP.GdipSetStringFormatAlign(fmt[0], TEXT_ALIGN[el.textAlignment] or STR_ALIGN_NEAR)
        GP.GdipSetStringFormatLineAlign(fmt[0], STR_ALIGN_CENTER)

        local brush = ffi.new("void*[1]")
        GP.GdipCreateSolidFill(argb, brush)

        local f  = el.frame
        local rc = ffi.new("GpRectF")
        rc.X, rc.Y          = logi(f.x), logi(f.y)
        rc.Width, rc.Height = logi(f.w), logi(f.h)
        GP.GdipDrawString(gfx, toWide(el.text), -1, font[0], rc, fmt[0], brush[0])

        GP.GdipDeleteBrush(brush[0])
        GP.GdipDeleteStringFormat(fmt[0])
        GP.GdipDeleteFont(font[0])
        GP.GdipDeleteFontFamily(family[0])
    end

    -- image: draw a file into the element frame. el.image is a file path (string) or a
    -- table carrying .path (so an hs.image.imageFromPath-style value works). Loaded
    -- images are cached for the process life -- GDI+ owns the handle; never disposed.
    local imageCache = {}
    local function loadImage(pathStr)
        if imageCache[pathStr] ~= nil then return imageCache[pathStr] end
        local img = ffi.new("void*[1]")
        local ok  = GP.GdipLoadImageFromFile(toWide(pathStr), img) == 0 and img[0] ~= nil
        imageCache[pathStr] = ok and img or false   -- cache the box: anchors the pointer
        return imageCache[pathStr]
    end
    local function drawImage(gfx, el, phW, phH)
        local src     = el.image
        local pathStr = (type(src) == "table" and src.path)
                        or (type(src) == "string" and src) or nil
        if not pathStr then return end
        local box = loadImage(pathStr)
        if not box then return end
        local x, y, w, h = physFrame(el, phW, phH)
        GP.GdipDrawImageRect(gfx, box[0], x, y, w, h)
    end

    -- Draw every element in append order; unknown types are skipped. Missing colours
    -- default to the deepslate/parchment alert palette.
    local function drawScene(gfx, rec, phW, phH)
        GP.GdipSetSmoothingMode(gfx, SMOOTHING_ANTIALIAS)
        GP.GdipSetTextRenderingHint(gfx, TEXT_ANTIALIAS)
        for _, el in ipairs(rec.elements) do
            local t = el.type
            if     t == "rectangle" then drawRect(gfx, el, phW, phH, rec)
            elseif t == "oval" or t == "circle" or t == "ellipse" then drawOval(gfx, el, phW, phH)
            elseif t == "segments" or t == "line" then drawSegments(gfx, el)
            elseif t == "text"     then drawText(gfx, el)
            elseif t == "image"    then drawImage(gfx, el, phW, phH)
            end
        end
    end
-- END --

local canvas = {}

-- windowLevels / windowBehaviors: numeric tables mudscript indexes + OR-combines --
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

    -- Push the current DIB to the window via UpdateLayeredWindow with the given
    -- whole-window constant alpha. Reused by render (after a redraw), :alpha, and a
    -- position-only :frame (all without re-drawing the bitmap).
    local function push(self)
        if self._closed or not self._hwnd or not self._memDC then return end
        local pt   = ffi.new("POINT"); pt.x = logi(self._frame.x); pt.y = logi(self._frame.y)
        local sz   = ffi.new("SIZE");  sz.cx = self._dibW;        sz.cy = self._dibH
        local src  = ffi.new("POINT"); src.x = 0; src.y = 0
        local bf   = ffi.new("BLENDFUNCTION")
        bf.BlendOp             = AC_SRC_OVER
        bf.BlendFlags          = 0
        bf.SourceConstantAlpha = math.max(0, math.min(255, math.floor(self._alpha * 255 + 0.5)))
        bf.AlphaFormat         = AC_SRC_ALPHA
        U.UpdateLayeredWindow(self._hwnd, nil, pt, sz, self._memDC, src, 0, bf, ULW_ALPHA)
    end

    -- (Re)draw the element scene into a physical-size DIB, then push it. Rebuilds the
    -- DIB only when the physical size changes. GDI+ failures are swallowed (never crash
    -- the pump) and logged once.
    local function render(self)
        if self._closed or not self._hwnd or not gdiplusOk then return end
        local phW = math.max(1, logi(self._frame.w))
        local phH = math.max(1, logi(self._frame.h))

        local ok, err = pcall(function()
            if not self._memDC or self._dibW ~= phW or self._dibH ~= phH then
                if self._memDC then
                    if self._hbitmap then G.DeleteObject(self._hbitmap) end
                    G.DeleteDC(self._memDC)
                end
                self._memDC = G.CreateCompatibleDC(nil)
                local bmi = ffi.new("BITMAPINFOHEADER")
                bmi.biSize        = ffi.sizeof("BITMAPINFOHEADER")
                bmi.biWidth       = phW
                bmi.biHeight      = -phH        -- negative: top-down
                bmi.biPlanes      = 1
                bmi.biBitCount    = 32
                bmi.biCompression = BI_RGB
                local bits = ffi.new("void*[1]")
                self._hbitmap = G.CreateDIBSection(self._memDC, bmi, DIB_RGB_COLORS, bits, nil, 0)
                self._bits    = bits[0]
                G.SelectObject(self._memDC, self._hbitmap)
                self._dibW, self._dibH = phW, phH
            end

            -- Draw into the DIB memory as a premultiplied GDI+ bitmap (shares scan0).
            local gpbmp = ffi.new("void*[1]")
            GP.GdipCreateBitmapFromScan0(phW, phH, phW * 4, PF_32BPP_PARGB,
                                         ffi.cast("unsigned char*", self._bits), gpbmp)
            local gfx = ffi.new("void*[1]")
            GP.GdipGetImageGraphicsContext(gpbmp[0], gfx)
            GP.GdipGraphicsClear(gfx[0], 0)             -- fully transparent
            drawScene(gfx[0], self._rec, phW, phH)
            GP.GdipDeleteGraphics(gfx[0])
            GP.GdipDisposeImage(gpbmp[0])               -- flushes into the DIB
        end)
        if not ok and not renderErrLogged then
            renderErrLogged = true
            io.stderr:write("hs.canvas: render error (swallowed): " .. tostring(err) .. "\n")
        end

        push(self)
    end

    function Canvas:level(n)
        if n == nil then return self._level end
        self._level = n
        return self
    end
    function Canvas:behavior(_) return self end

    -- Keep-on-top tick: re-front a top-most canvas every FRONT_MS so the shell's
    -- :bringToFront can't bury it (both live in the one Win32 topmost band).
    local function startKeepFront(self)
        if self._frontTimer or (self._level and self._level < 0) then return end
        self._frontTimer = timer.doEvery(FRONT_MS, function()
            if self._closed or not self._hwnd then return end
            U.SetWindowPos(self._hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_FRONT)
        end)
    end
    local function stopKeepFront(self)
        if self._frontTimer then self._frontTimer:stop(); self._frontTimer = nil end
    end

    function Canvas:alpha(a)
        if a == nil then return self._alpha end
        self._alpha = a
        push(self)          -- constant-alpha change only; no redraw
        return self
    end

    function Canvas:frame(r)
        local f = self._frame
        if r == nil then return { x = f.x, y = f.y, w = f.w, h = f.h } end
        local resized = (r.w and r.w ~= f.w) or (r.h and r.h ~= f.h)
        f.x = r.x or f.x; f.y = r.y or f.y; f.w = r.w or f.w; f.h = r.h or f.h
        if not self._closed and self._hwnd then
            if resized then render(self) else push(self) end   -- move-only just re-pushes
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
            end
        end
        if self._hwnd then render(self) end
        return self
    end

    -- elementAttribute(i, key, value): mutate one element in place and re-render.
    function Canvas:elementAttribute(i, key, value)
        local el = self._rec.elements[i]
        if el then
            el[key] = value
            if i == 1 and key == "roundedRectRadii" and value and value.xRadius then
                self._rec.radius = value.xRadius
            end
            if self._hwnd then render(self) end
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
                logi(f.x), logi(f.y), logi(f.w), logi(f.h), nil, nil, hInst, nil)
            if hwnd == nil then error("hs.canvas: CreateWindowExA failed") end
            self._hwnd     = hwnd
            self._key      = keyOf(hwnd)
            self._rec.self = self
            records[self._key] = self._rec
        end
        render(self)   -- draw + push BEFORE showing, so the first frame is never garbage
        U.ShowWindow(self._hwnd, SW_SHOWNOACTIVATE)
        U.SetWindowPos(self._hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_FRONT)
        startKeepFront(self)
        return self
    end

    function Canvas:topLeft(p)
        if p == nil then return { x = self._frame.x, y = self._frame.y } end
        return self:frame({ x = p.x, y = p.y })
    end
    function Canvas:size(s)
        if s == nil then return { w = self._frame.w, h = self._frame.h } end
        return self:frame({ w = s.w, h = s.h })
    end

    function Canvas:hide()
        stopKeepFront(self)
        if not self._closed and self._hwnd then U.ShowWindow(self._hwnd, 0) end  -- SW_HIDE
        return self
    end

    function Canvas:delete()
        if self._closed then return self end
        self._closed = true
        stopKeepFront(self)
        if self._memDC then
            if self._hbitmap then G.DeleteObject(self._hbitmap) end
            G.DeleteDC(self._memDC)
            self._memDC, self._hbitmap, self._bits = nil, nil, nil
        end
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
        return setmetatable({
            _frame      = { x = rect.x or 0, y = rect.y or 0, w = rect.w or 0, h = rect.h or 0 },
            _alpha      = 1,
            _level      = 0,          -- >=0 => top-most (default); drives keep-on-top
            _closed     = false,
            _hwnd       = nil,
            _frontTimer = nil,
            _memDC      = nil,
            _hbitmap    = nil,
            _bits       = nil,
            _dibW       = nil,
            _dibH       = nil,
            _rec        = { elements = {}, radius = DEFAULT_RADIUS, mouseCb = nil, tracking = false },
        }, Canvas)
    end

    function canvas.elementCount() return 0 end
-- END --

return canvas
