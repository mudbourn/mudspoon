local ffi  = require("ffi")
local host = require("hs.foundation")
local U    = host.C.user32
local G    = host.C.gdi32

ffi.cdef[[
unsigned int GetDpiForSystem(void);    /* user32, Win10 1607+ */
HDC          GetDC(HWND);
int          ReleaseDC(HWND, HDC);
int          GetDeviceCaps(HDC, int);  /* gdi32 */
]]

local LOGPIXELSX = 88   -- GetDeviceCaps index for horizontal DPI
local cached                            -- resolved once, after boot awareness is set

-- Resolve the system DPI. GetDpiForSystem is the modern, window-free query; fall back
-- to the screen DC's LOGPIXELSX on pre-1607 Windows. Any failure => 96 (scale 1.0).
local function resolve()
    local dpi
    if not pcall(function() dpi = tonumber(U.GetDpiForSystem()) end) then dpi = nil end
    if not dpi or dpi == 0 then
        pcall(function()
            local hdc = U.GetDC(nil)
            if hdc ~= nil then
                dpi = tonumber(G.GetDeviceCaps(hdc, LOGPIXELSX))
                U.ReleaseDC(nil, hdc)
            end
        end)
    end
    if not dpi or dpi == 0 then dpi = 96 end
    return dpi / 96
end

local dpiscale = {}

-- get(): the cached scale factor. Cached on first call (which happens at the first
-- window creation, well after boot sets awareness, so the value is accurate).
function dpiscale.get()
    if not cached then cached = resolve() end
    return cached
end

return dpiscale
