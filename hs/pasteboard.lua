local host = require("hs.foundation")
local ffi  = host.ffi
local U     = host.C.user32
local K     = host.C.kernel32

-- Clipboard FFI (functions only; every base type is Foundation's) --
    -- HANDLE / HGLOBAL / void* are already typedef'd in foundation.lua, so this
    -- cdef declares ONLY prototypes -- a duplicate typedef would be a load error.
    ffi.cdef[[
BOOL    OpenClipboard(HWND);
BOOL    CloseClipboard(void);
BOOL    EmptyClipboard(void);
HANDLE  SetClipboardData(UINT, HANDLE);
HANDLE  GetClipboardData(UINT);
DWORD   GetClipboardSequenceNumber(void);
HANDLE  GlobalAlloc(UINT, size_t);
void*   GlobalLock(HANDLE);
BOOL    GlobalUnlock(HANDLE);
]]
-- END --

-- Constants --
    local CF_TEXT       = 1
    local GMEM_MOVEABLE = 0x0002
-- END --

local pasteboard = {}

-- setContents --
    -- OpenClipboard(NULL) -> EmptyClipboard -> allocate a moveable global block,
    -- copy the bytes + a NUL terminator into it, hand it to SetClipboardData. On
    -- success the clipboard OWNS the block, so we must NOT free it. Returns true
    -- only when the whole handshake succeeds.
    function pasteboard.setContents(text)
        text = tostring(text or "")
        if U.OpenClipboard(nil) == 0 then return false end

        local ok = false
        -- EmptyClipboard both clears prior contents and takes ownership for us.
        if U.EmptyClipboard() ~= 0 then
            local n   = #text
            local mem = K.GlobalAlloc(GMEM_MOVEABLE, n + 1)
            if mem ~= nil then
                local p = K.GlobalLock(mem)
                if p ~= nil then
                    ffi.copy(p, text, n)
                    ffi.cast("char*", p)[n] = 0  -- NUL terminator CF_TEXT requires
                    K.GlobalUnlock(mem)
                    -- Ownership transfers to the clipboard on success; do not free.
                    if U.SetClipboardData(CF_TEXT, mem) ~= nil then ok = true end
                end
            end
        end

        U.CloseClipboard()
        return ok
    end
-- END --

-- getContents (internal) --
    -- Read CF_TEXT back out as a Lua string, or nil when the clipboard holds no
    -- text / cannot be opened.
    function pasteboard.getContents()
        if U.OpenClipboard(nil) == 0 then return nil end
        local out = nil
        local h = U.GetClipboardData(CF_TEXT)
        if h ~= nil then
            local p = K.GlobalLock(h)
            if p ~= nil then
                out = ffi.string(ffi.cast("char*", p))  -- NUL-terminated CF_TEXT
                K.GlobalUnlock(h)
            end
        end
        U.CloseClipboard()
        return out
    end
-- END --

-- watcher --
    local Watcher = {}
    Watcher.__index = Watcher

    local POLL_MS = 250  -- clipboard changes are human-paced; 4Hz is plenty

    function Watcher:start()
        if self._handle and self._handle.live then return self end
        -- Seed from the current sequence so we only fire on CHANGES after start.
        self._seq = tonumber(U.GetClipboardSequenceNumber())
        self._handle = host.schedule(POLL_MS, function()
            local seq = tonumber(U.GetClipboardSequenceNumber())
            if seq ~= self._seq then
                self._seq = seq
                local text = pasteboard.getContents()
                local ok, err = pcall(self._cb, text)
                if not ok then
                    io.stderr:write("hs.pasteboard watcher callback error: "
                        .. tostring(err) .. "\n")
                end
            end
        end, POLL_MS)
        return self
    end

    function Watcher:stop()
        if self._handle then self._handle:cancel(); self._handle = nil end
        return self
    end

    pasteboard.watcher = {}
    function pasteboard.watcher.new(callback)
        return setmetatable({ _cb = callback, _seq = 0, _handle = nil }, Watcher)
    end
-- END --

return pasteboard
