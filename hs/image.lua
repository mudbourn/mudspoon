local ffi = require("ffi")

local host = require("hs.foundation")

-- Own FFI surface --
    local K = host.C.kernel32
    local G = host.C.gdi32
    local U = host.C.user32
    local GP = ffi.load("gdiplus")

    ffi.cdef[[
typedef struct {
    DWORD biSize;
    LONG  biWidth;
    LONG  biHeight;
    WORD  biPlanes;
    WORD  biBitCount;
    DWORD biCompression;
    DWORD biSizeImage;
    LONG  biXPelsPerMeter;
    LONG  biYPelsPerMeter;
    DWORD biClrUsed;
    DWORD biClrImportant;
} MUDSPOON_IMG_BMIH;

typedef struct {
    unsigned int GdiplusVersion;
    void* DebugEventCallback;
    int Suppress1;
    int Suppress2;
} MUDSPOON_IMG_GPSTARTUP;

typedef struct {
    unsigned long Data1;
    unsigned short Data2;
    unsigned short Data3;
    unsigned char Data4[8];
} MUDSPOON_IMG_GUID;

int GdipSaveImageToFile(void*, const unsigned short*, const MUDSPOON_IMG_GUID*, const void*);
int MultiByteToWideChar(unsigned int, DWORD, const char*, int, unsigned short*, int);
]]

    local protos = {
        "HDC CreateCompatibleDC(HDC);",
        "BOOL DeleteDC(HDC);",
        "void* CreateDIBSection(HDC, const void*, unsigned int, void**, HANDLE, DWORD);",
        "HGDIOBJ SelectObject(HDC, HGDIOBJ);",
        "BOOL DeleteObject(HGDIOBJ);",
        "BOOL BitBlt(HDC, int, int, int, int, HDC, int, int, DWORD);",
        "HDC GetDC(HWND);",
        "int ReleaseDC(HWND, HDC);",
        "int GdiplusStartup(ULONG_PTR*, const void*, void*);",
        "int GdipCreateBitmapFromScan0(int, int, int, int, unsigned char*, void**);",
        "int GdipDisposeImage(void*);",
    }

    for _, proto in ipairs(protos) do
        pcall(ffi.cdef, proto)
    end
-- END --

-- Constants --
    local SRCCOPY = 0x00CC0020
    local CAPTUREBLT = 0x40000000
    local PIXEL_FORMAT_32BPP_RGB = 0x00022009
    local CP_UTF8 = 65001
-- END --

-- GDI+ session --
    local gdipToken = nil

    local function gdipReady()
        if gdipToken then return true end

        local token = ffi.new("ULONG_PTR[1]")
        local input = ffi.new("MUDSPOON_IMG_GPSTARTUP")
        input.GdiplusVersion = 1

        if GP.GdiplusStartup(token, ffi.cast("void*", input), nil) ~= 0 then
            return false
        end

        gdipToken = token[0]

        return true
    end

    local pngClsid = ffi.new("MUDSPOON_IMG_GUID", {
        0x557CF406,
        0x1A04,
        0x11D3,
        { 0x9A, 0x73, 0x00, 0x00, 0xF8, 0x1E, 0xF3, 0x2E },
    })
-- END --

-- Image object --
    local Image = {}
    Image.__index = Image

    -- Builds an image that owns a top-down BGRA buffer
    local function newImage(buf, w, h)
        return setmetatable({
            _buf = buf,
            _w = w,
            _h = h,
        }, Image)
    end

    -- :size() -> { w, h } in pixels
    function Image:size()
        return { w = self._w, h = self._h }
    end

    -- :colorAt(point) -> { red, green, blue, alpha } as 0..1 floats, or nil off the image
    function Image:colorAt(point)
        local x = math.floor(tonumber(point and point.x) or 0)
        local y = math.floor(tonumber(point and point.y) or 0)

        if x < 0 or y < 0 or x >= self._w or y >= self._h then return nil end

        local i = (y * self._w + x) * 4

        return {
            red = self._buf[i + 2] / 255,
            green = self._buf[i + 1] / 255,
            blue = self._buf[i] / 255,
            alpha = 1,
        }
    end

    -- :saveToFile(path[, filetype]) -> true on success. Only PNG is written.
    function Image:saveToFile(path, filetype)
        if type(path) ~= "string" or path == "" then return false end
        if filetype and tostring(filetype):upper() ~= "PNG" then return false end
        if not gdipReady() then return false end

        local need = K.MultiByteToWideChar(CP_UTF8, 0, path, -1, nil, 0)
        if need <= 0 then return false end

        local wide = ffi.new("unsigned short[?]", need)
        K.MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, need)

        local bitmap = ffi.new("void*[1]")
        local status = GP.GdipCreateBitmapFromScan0(self._w, self._h, self._w * 4, PIXEL_FORMAT_32BPP_RGB, self._buf, bitmap)
        if status ~= 0 then return false end

        local saved = GP.GdipSaveImageToFile(bitmap[0], wide, pngClsid, nil)

        GP.GdipDisposeImage(bitmap[0])

        return saved == 0
    end
-- END --

-- Public API --
    local image = {}

    -- hs.image._captureScreen(x, y, w, h) -> image of the physical screen rect, or nil
    function image._captureScreen(x, y, w, h)
        if w < 1 or h < 1 then return nil end

        local screenDC = U.GetDC(nil)
        if screenDC == nil then return nil end

        local memDC = G.CreateCompatibleDC(screenDC)
        local result = nil

        if memDC ~= nil then
            local bmi = ffi.new("MUDSPOON_IMG_BMIH")
            bmi.biSize = ffi.sizeof("MUDSPOON_IMG_BMIH")
            bmi.biWidth = w
            bmi.biHeight = -h
            bmi.biPlanes = 1
            bmi.biBitCount = 32
            bmi.biCompression = 0

            local bits = ffi.new("void*[1]")
            local dib = G.CreateDIBSection(screenDC, bmi, 0, bits, nil, 0)

            if dib ~= nil and bits[0] ~= nil then
                local old = G.SelectObject(memDC, dib)

                if G.BitBlt(memDC, 0, 0, w, h, screenDC, x, y, SRCCOPY + CAPTUREBLT) ~= 0 then
                    local buf = ffi.new("uint8_t[?]", w * h * 4)
                    ffi.copy(buf, bits[0], w * h * 4)
                    result = newImage(buf, w, h)
                end

                G.SelectObject(memDC, old)
            end

            if dib ~= nil then G.DeleteObject(dib) end

            G.DeleteDC(memDC)
        end

        U.ReleaseDC(nil, screenDC)

        return result
    end
-- END --

return image
