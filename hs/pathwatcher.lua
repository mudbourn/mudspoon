-- hs.pathwatcher  (ReadDirectoryChangesW via LuaJIT FFI, runloop-driven) --
    -- A Hammerspoon-shaped hs.pathwatcher. The slice mudscript actually uses:
    --   hs.pathwatcher.new(path, callback)   -- callback(paths, flagTables)
    --   watcher:start()  -> watcher
    --   watcher:stop()   -> watcher
    -- callback receives the array of changed absolute paths and a parallel array of
    -- Hammerspoon-style flag tables ({itemCreated=true}, {itemModified=true}, ...).
    --
    -- ------------------------- Single-thread integration --------------------------
    -- Backed by ReadDirectoryChangesW in ASYNCHRONOUS (overlapped) mode, driven off
    -- the ONE hs.foundation runloop -- NOT its own thread. start() opens the directory
    -- with FILE_FLAG_OVERLAPPED, issues one ReadDirectoryChangesW against a manual-
    -- reset event, and schedules a host.schedule() tick. Each tick does a zero-timeout
    -- WaitForSingleObject on the event: when it signals, we GetOverlappedResult, parse
    -- the FILE_NOTIFY_INFORMATION buffer, fire the callback, then RE-ISSUE the read.
    -- No blocking wait ever happens on the runloop, so the pump stays responsive --
    -- the same non-blocking-poll shape hs.task uses for its child process.
    --
    -- Depends on hs.foundation for shared Win32 TYPES (HANDLE, DWORD, BOOL, ULONG_PTR)
    -- and the loaded kernel32 handle + the runloop. Per the frozen cdef-ownership rule
    -- this file cdef's ONLY its own OVERLAPPED / FILE_NOTIFY_INFORMATION structs and
    -- the kernel32 FUNCTIONS it calls. CloseHandle / WaitForSingleObject are ALSO
    -- declared by hs.task and MultiByteToWideChar / WideCharToMultiByte by hs.webview;
    -- those redeclarations are IDENTICAL, which LuaJIT allows (only a type MISMATCH
    -- errors). Every unique symbol here (CreateFileW, ReadDirectoryChangesW, ...) is
    -- declared nowhere else in the tree.
    --
    -- UNVERIFIED SCAFFOLD: PARSE-checked reasoning only, never run on Windows. The
    -- FILE_NOTIFY_INFORMATION walk (NextEntryOffset chaining, FileNameLength in BYTES,
    -- FileName at offset 12) and the overlapped completion timing are the riskiest
    -- points -- flagged inline with "RISK:".
-- END --

local host = require("hs.foundation")
local ffi  = host.ffi
local bit  = host.bit
local K    = host.C.kernel32

-- Own FFI surface (unique structs + kernel32 fns; shared types come from Foundation) --
    ffi.cdef[[
/* OVERLAPPED: we use only the manual event field; Offset/OffsetHigh stay zero (a
 * directory handle has no file offset). ULONG_PTR/DWORD/HANDLE come from Foundation. */
typedef struct {
  ULONG_PTR Internal; ULONG_PTR InternalHigh;
  DWORD Offset; DWORD OffsetHigh; HANDLE hEvent;
} OVERLAPPED;

/* FILE_NOTIFY_INFORMATION: FileNameLength is in BYTES; FileName is WCHAR (unsigned
 * short) and NOT NUL-terminated. FileName starts at byte offset 12. */
typedef struct {
  DWORD NextEntryOffset; DWORD Action; DWORD FileNameLength; unsigned short FileName[1];
} FILE_NOTIFY_INFORMATION;

/* --- Unique kernel32 functions (declared nowhere else) --- */
HANDLE CreateFileW(const unsigned short*, DWORD, DWORD, void*, DWORD, DWORD, HANDLE);
HANDLE CreateEventA(void*, BOOL, BOOL, const char*);
BOOL   ResetEvent(HANDLE);
BOOL   ReadDirectoryChangesW(HANDLE, void*, DWORD, BOOL, DWORD, DWORD*, OVERLAPPED*, void*);
BOOL   GetOverlappedResult(HANDLE, OVERLAPPED*, DWORD*, BOOL);
unsigned long GetFileAttributesW(const unsigned short*);

/* --- Identical redeclarations (also in hs.task / hs.webview; LuaJIT allows a match) --- */
DWORD WaitForSingleObject(HANDLE, DWORD);
BOOL  CloseHandle(HANDLE);
int   MultiByteToWideChar(unsigned int, unsigned long, const char*, int, unsigned short*, int);
int   WideCharToMultiByte(unsigned int, unsigned long, const unsigned short*, int,
                          char*, int, const char*, void*);
]]
-- END --

-- Constants --
    local CP_UTF8                = 65001
    local INVALID_HANDLE_VALUE   = ffi.cast("HANDLE", ffi.cast("intptr_t", -1))
    local INVALID_FILE_ATTRIBUTES= 0xFFFFFFFF
    local FILE_ATTRIBUTE_DIRECTORY = 0x10

    local FILE_LIST_DIRECTORY    = 0x0001
    local FILE_SHARE_READ        = 0x0001
    local FILE_SHARE_WRITE       = 0x0002
    local FILE_SHARE_DELETE      = 0x0004
    local OPEN_EXISTING          = 3
    local FILE_FLAG_BACKUP_SEMANTICS = 0x02000000  -- required for a directory handle
    local FILE_FLAG_OVERLAPPED       = 0x40000000

    -- What to watch for. Union of the changes Hammerspoon surfaces.
    local FILTER = bit.bor(0x1, 0x2, 0x4, 0x8, 0x10, 0x40)
    -- FILE_NAME | DIR_NAME | ATTRIBUTES | SIZE | LAST_WRITE | CREATION

    -- FILE_ACTION_* -> Hammerspoon flag table.
    local ACTION_FLAGS = {
        [1] = { itemCreated  = true },   -- FILE_ACTION_ADDED
        [2] = { itemRemoved  = true },   -- FILE_ACTION_REMOVED
        [3] = { itemModified = true },   -- FILE_ACTION_MODIFIED
        [4] = { itemRenamed  = true },   -- FILE_ACTION_RENAMED_OLD_NAME
        [5] = { itemRenamed  = true },   -- FILE_ACTION_RENAMED_NEW_NAME
    }

    local WAIT_OBJECT_0 = 0
    local POLL_MS       = 50
    local BUF_BYTES     = 64 * 1024      -- FILE_NOTIFY_INFORMATION ring buffer
-- END --

-- UTF-8 <-> UTF-16 helpers --
    -- toWide(s) -> NUL-terminated unsigned short[]; caller keeps it for the API call.
    local function toWide(s)
        s = tostring(s or "")
        local need = K.MultiByteToWideChar(CP_UTF8, 0, s, #s, nil, 0)
        local buf  = ffi.new("unsigned short[?]", need + 1)
        K.MultiByteToWideChar(CP_UTF8, 0, s, #s, buf, need)
        buf[need] = 0
        return buf
    end

    -- fromWideN(ptr, chars) -> Lua UTF-8 string from a NON-terminated wide run.
    local function fromWideN(ptr, chars)
        if ptr == nil or chars <= 0 then return "" end
        local need = K.WideCharToMultiByte(CP_UTF8, 0, ptr, chars, nil, 0, nil, nil)
        if need <= 0 then return "" end
        local buf = ffi.new("char[?]", need)
        K.WideCharToMultiByte(CP_UTF8, 0, ptr, chars, buf, need, nil, nil)
        return ffi.string(buf, need)
    end
-- END --

-- Path helpers --
    local function isDirectory(path)
        local attr = K.GetFileAttributesW(toWide(path))
        if attr == INVALID_FILE_ATTRIBUTES then return false end
        return bit.band(attr, FILE_ATTRIBUTE_DIRECTORY) ~= 0
    end

    local function normSlashes(p) return (p:gsub("/", "\\")) end

    -- Resolve which directory to actually watch, and the parent prefix used to build
    -- absolute change paths. A directory path is watched directly; a file path watches
    -- its parent directory (ReadDirectoryChangesW needs a directory handle).
    local function resolveDir(path)
        path = normSlashes(path):gsub("\\+$", "")
        if isDirectory(path) then return path end
        local parent = path:match("^(.*)\\[^\\]+$")
        return parent or path
    end
-- END --

local pathwatcher = {}

-- The watcher object --
    local Watcher = {}
    Watcher.__index = Watcher

    -- Parse the FILE_NOTIFY_INFORMATION chain in self._buf[0..bytes-1] into parallel
    -- {paths, flagTables} arrays, resolving each name against the watched directory.
    local function parseNotifications(self, bytes)
        local paths, flags = {}, {}
        local base = ffi.cast("char*", self._buf)
        local off  = 0
        while off < bytes do
            local info = ffi.cast("FILE_NOTIFY_INFORMATION*", base + off)
            local nameLen = tonumber(info.FileNameLength)          -- BYTES
            -- FileName sits at byte offset 12 in the record (3 x DWORD header).
            local namePtr = ffi.cast("unsigned short*", base + off + 12)
            local name    = fromWideN(namePtr, nameLen / 2)
            if name ~= "" then
                paths[#paths + 1] = self._dir .. "\\" .. name
                flags[#flags + 1] = ACTION_FLAGS[tonumber(info.Action)] or { itemModified = true }
            end
            local nxt = tonumber(info.NextEntryOffset)
            if nxt == 0 then break end
            off = off + nxt
        end
        return paths, flags
    end

    -- Issue (or re-issue) one overlapped ReadDirectoryChangesW. Returns false on
    -- failure (the watcher then self-stops).
    local function issueRead(self)
        K.ResetEvent(self._event)
        self._ovl.hEvent = self._event
        local ok = K.ReadDirectoryChangesW(self._hDir, self._buf, BUF_BYTES,
            true,               -- watch subtree (recursive), Hammerspoon default
            FILTER, self._bytesRet, self._ovl, nil)
        return ok ~= 0
    end

    -- One runloop tick: has the overlapped read completed? If so, harvest + re-arm.
    local function poll(self)
        if not self._running then return end
        -- RISK: manual-reset event is signalled by the OS on completion; a zero
        -- timeout makes this a non-blocking probe so the pump is never stalled.
        if K.WaitForSingleObject(self._event, 0) ~= WAIT_OBJECT_0 then return end

        local got = ffi.new("DWORD[1]")
        if K.GetOverlappedResult(self._hDir, self._ovl, got, false) == 0 then
            -- Completed but result fetch failed; try to re-arm, else stop.
            if not issueRead(self) then self:stop() end
            return
        end

        local bytes = tonumber(got[0])
        if bytes > 0 then
            local paths, flags = parseNotifications(self, bytes)
            if #paths > 0 and self._cb then
                local ok, err = pcall(self._cb, paths, flags)
                if not ok then
                    io.stderr:write("hs.pathwatcher callback error: " .. tostring(err) .. "\n")
                end
            end
        end
        -- Re-arm for the next batch. A zero-byte return means the buffer overflowed;
        -- we simply re-issue and continue (some events are lost, as on macOS coalescing).
        if self._running and not issueRead(self) then self:stop() end
    end

    -- :start() -> self. Opens the directory handle + event and arms the first read.
    -- Idempotent: starting an already-running watcher is a no-op.
    function Watcher:start()
        if self._running then return self end

        local share = bit.bor(FILE_SHARE_READ, FILE_SHARE_WRITE, FILE_SHARE_DELETE)
        local flags = bit.bor(FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OVERLAPPED)
        local h = K.CreateFileW(toWide(self._dir), FILE_LIST_DIRECTORY, share, nil,
                                OPEN_EXISTING, flags, nil)
        if h == INVALID_HANDLE_VALUE then
            io.stderr:write("hs.pathwatcher: CreateFileW failed for " .. self._dir .. "\n")
            return self
        end
        self._hDir     = h
        self._event    = K.CreateEventA(nil, true, false, nil)   -- manual-reset, unsignalled
        self._buf      = ffi.new("char[?]", BUF_BYTES)
        self._ovl      = ffi.new("OVERLAPPED")
        self._bytesRet = ffi.new("DWORD[1]")
        self._running  = true

        if not issueRead(self) then
            io.stderr:write("hs.pathwatcher: initial ReadDirectoryChangesW failed\n")
            self:stop()
            return self
        end
        -- Repeating tick on the ONE runloop -- no thread.
        self._handle = host.schedule(POLL_MS, function() poll(self) end, POLL_MS)
        return self
    end

    -- :stop() -> self. Cancels the tick and releases the handle + event. Idempotent.
    function Watcher:stop()
        if not self._running and not self._hDir then return self end
        self._running = false
        if self._handle then self._handle:cancel(); self._handle = nil end
        if self._hDir then K.CloseHandle(self._hDir); self._hDir = nil end
        if self._event then K.CloseHandle(self._event); self._event = nil end
        return self
    end
-- END --

-- hs.pathwatcher.new(path, callback) -> watcher --
    -- callback(paths, flagTables). The watcher is created STOPPED (Hammerspoon
    -- semantics); call :start() to begin delivering events.
    function pathwatcher.new(path, callback)
        return setmetatable({
            _dir      = resolveDir(tostring(path or ".")),
            _cb       = callback,
            _running  = false,
        }, Watcher)
    end
-- END --

return pathwatcher
