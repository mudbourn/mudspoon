-- hs.dpiscale  (leaf: the system DPI scale factor) --
    -- One number: physical pixels per logical pixel (1.0 at 96dpi/100%, 1.25 at 125%,
    -- 1.5 at 150%, ...). It is the seam that lets the rest of the hs layer speak ONE
    -- logical coordinate space (mac-like points) while windows are drawn at native
    -- device pixels: hs.screen divides physical monitor rects by it (so mudscript's
    -- layout math is unchanged from the old DPI-unaware space), and hs.canvas /
    -- hs.webview multiply their logical rects + font sizes by it when creating windows.
    --
    -- MASTER SWITCH: this returns 1.0 unless the process is DPI-aware. run_mudscript
    -- sets awareness at boot; a DPI-UNAWARE process always reports 96dpi here, so with
    -- awareness off every scale() is 1.0 and all the ×scale / ÷scale callers become
    -- identity -- i.e. exactly the old behaviour. That makes the whole hi-dpi change
    -- revert with a single toggle (see run_mudscript's MUDSPOON_HIDPI gate).
    --
    -- Depends on FOUNDATION for the loaded user32/gdi32 + shared types; cdefs ONLY its
    -- own unique prototypes (GetDpiForSystem / GetDC / ReleaseDC / GetDeviceCaps).
-- END --

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
