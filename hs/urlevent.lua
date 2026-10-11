local host = require("hs.foundation")
local ffi  = host.ffi

-- shell32 (guarded; missing DLL => openURL no-ops) --
    local okShell, shell32 = pcall(ffi.load, "shell32")
    if okShell then
        -- HWND / LPCSTR / HINSTANCE are Foundation's typedefs; declare only the fn.
        ffi.cdef[[
HINSTANCE ShellExecuteA(HWND, LPCSTR, LPCSTR, LPCSTR, LPCSTR, int);
]]
    else
        io.stderr:write("[hs.urlevent] shell32 unavailable; openURL will no-op\n")
    end

    local SW_SHOWNORMAL = 1
-- END --

local urlevent = {}

-- openURL --
    -- Returns true when the launch was dispatched. ShellExecuteA returns an
    -- HINSTANCE whose integer value is > 32 on success (Win32 legacy contract).
    function urlevent.openURL(url)
        if not okShell or type(url) ~= "string" then return false end
        local rc = shell32.ShellExecuteA(nil, "open", url, nil, nil, SW_SHOWNORMAL)
        return tonumber(ffi.cast("intptr_t", rc)) > 32
    end
-- END --

return urlevent
