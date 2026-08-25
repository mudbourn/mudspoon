-- hs.fs  (leaf) --
    -- Filesystem queries, matching Hammerspoon's `hs.fs` (which is LuaFileSystem).
    -- On Windows/LuaJIT there is no `lfs` binary, so this is implemented over
    -- Win32 via FFI, the same way hs/screen.lua stands up its module.
    --
    -- Depends on FOUNDATION (`hs.foundation`) for shared FFI TYPES only. Per the
    -- frozen cdef-ownership rule: foundation cdefs the common typedefs (HANDLE,
    -- DWORD, BOOL, LONG, WORD, BYTE, LPCSTR ...) and loads the libs once (exposed
    -- as host.C.kernel32/.user32/.gdi32). This module cdefs ONLY its own unique
    -- function prototypes and the two file-API structs (WIN32_FIND_DATAA,
    -- WIN32_FILE_ATTRIBUTE_DATA + FILETIME), and never redeclares a shared type.
    --
    -- Coordination note: the file APIs below (FindFirstFileA/FindNextFileA/
    -- FindClose, GetFileAttributesExA, CreateDirectoryA, RemoveDirectoryA,
    -- GetLastError) are OWNED here. No other module should cdef them.
    --
    -- Scope: only the four functions the consumer uses -- attributes, dir, mkdir,
    -- rmdir. LFS's chdir/currentdir/lock/touch etc. are intentionally omitted.
-- END --

local ffi = require("ffi")
local bit = require("bit")

-- Foundation: shared types + the single loaded kernel32 handle. --
    -- Hard dependency. Foundation must load first so its shared typedefs
    -- (HANDLE, DWORD, BOOL, LPCSTR ...) exist for our cdef below. Reuse its
    -- single loaded kernel32 (host.C.kernel32); fall back to a fresh load only
    -- if that seam ever moves (harmless in LuaJIT -- C decls are process-global).
    local host = require("hs.foundation")
    local K = (host.C and host.C.kernel32) or ffi.load("kernel32")
-- END --

-- Own FFI surface (functions + unique structs only; shared types from Foundation) --
    -- WIN32_FIND_DATAA / WIN32_FILE_ATTRIBUTE_DATA field ORDER is load-bearing --
    -- it must match the Win32 headers exactly. Sizes are DWORD pairs; times are
    -- FILETIME (two DWORDs). cFileName is MAX_PATH (260); cAlternateFileName 14.
    ffi.cdef[[
typedef struct { DWORD dwLowDateTime; DWORD dwHighDateTime; } FILETIME;

typedef struct {
    DWORD    dwFileAttributes;
    FILETIME ftCreationTime;
    FILETIME ftLastAccessTime;
    FILETIME ftLastWriteTime;
    DWORD    nFileSizeHigh;
    DWORD    nFileSizeLow;
    DWORD    dwReserved0;
    DWORD    dwReserved1;
    char     cFileName[260];
    char     cAlternateFileName[14];
} WIN32_FIND_DATAA;

typedef struct {
    DWORD    dwFileAttributes;
    FILETIME ftCreationTime;
    FILETIME ftLastAccessTime;
    FILETIME ftLastWriteTime;
    DWORD    nFileSizeHigh;
    DWORD    nFileSizeLow;
} WIN32_FILE_ATTRIBUTE_DATA;

HANDLE FindFirstFileA(LPCSTR, WIN32_FIND_DATAA*);
BOOL   FindNextFileA(HANDLE, WIN32_FIND_DATAA*);
BOOL   FindClose(HANDLE);
BOOL   GetFileAttributesExA(LPCSTR, int, void*);
BOOL   CreateDirectoryA(LPCSTR, void*);
BOOL   RemoveDirectoryA(LPCSTR);
DWORD  GetLastError(void);
]]
-- END --

-- Constants --
    local FILE_ATTRIBUTE_DIRECTORY = 0x10
    local GetFileExInfoStandard    = 0     -- GET_FILEEX_INFO_LEVELS enum member
    -- INVALID_HANDLE_VALUE is (HANDLE)-1, not NULL. FindFirstFileA returns it on
    -- failure; comparing against a NULL HANDLE would miss the error.
    local INVALID_HANDLE_VALUE     = ffi.cast("HANDLE", -1)

    -- 100ns ticks between 1601-01-01 (FILETIME epoch) and 1970-01-01 (unix epoch).
    local FILETIME_EPOCH_DELTA     = 116444736000000000ULL
-- END --

-- Helpers --
    -- Fold a FILETIME (two 32-bit halves, 100ns ticks since 1601) into unix
    -- epoch SECONDS. Done in unsigned 64-bit cdata to avoid double precision
    -- loss, then narrowed to a Lua number. A zero FILETIME maps to 0.
    local function fileTimeToEpoch(ft)
        local ticks = ffi.cast("uint64_t", ft.dwHighDateTime) * 4294967296ULL
                    + ffi.cast("uint64_t", ft.dwLowDateTime)
        if ticks < FILETIME_EPOCH_DELTA then return 0 end
        return tonumber((ticks - FILETIME_EPOCH_DELTA) / 10000000ULL)
    end

    -- Combine the high/low DWORD size halves into a Lua number (64-bit safe).
    local function fileSize(high, low)
        local sz = ffi.cast("uint64_t", high) * 4294967296ULL
                 + ffi.cast("uint64_t", low)
        return tonumber(sz)
    end

    -- LFS-style string mode from Win32 attributes.
    local function modeOf(attrs)
        if bit.band(attrs, FILE_ATTRIBUTE_DIRECTORY) ~= 0 then return "directory" end
        return "file"
    end
-- END --

-- Public API --
    local fs = {}

    -- hs.fs.attributes(path [, aName]) -> table | value | nil --
        -- No aName: a table of LFS attributes, or nil if the path does not exist
        -- (the consumer uses this as an existence check -- must not error).
        -- With aName: just that field's value, or nil if the path is missing.
        function fs.attributes(path, aName)
            local data = ffi.new("WIN32_FILE_ATTRIBUTE_DATA")
            if K.GetFileAttributesExA(path, GetFileExInfoStandard, data) == 0 then
                return nil  -- missing / inaccessible: treat as "does not exist"
            end

            local attrs = tonumber(data.dwFileAttributes)
            local t = {
                mode         = modeOf(attrs),
                size         = fileSize(data.nFileSizeHigh, data.nFileSizeLow),
                modification = fileTimeToEpoch(data.ftLastWriteTime),
                access       = fileTimeToEpoch(data.ftLastAccessTime),
                change       = fileTimeToEpoch(data.ftLastWriteTime),  -- Win32 has no ctime; alias mtime
            }

            if aName ~= nil then
                return t[aName]  -- LFS single-attribute form
            end
            return t
        end
    -- END --

    -- hs.fs.dir(path) -> iterator --
        -- for name in hs.fs.dir(path) do ... end. Yields every entry INCLUDING
        -- "." and ".." (matching LFS). Raises if the path can't be opened (LFS
        -- raises too). FindFirstFileA's first hit IS "." for a real directory.
        function fs.dir(path)
            local fd   = ffi.new("WIN32_FIND_DATAA")
            local spec = path .. "\\*"
            local h    = K.FindFirstFileA(spec, fd)
            if h == INVALID_HANDLE_VALUE then
                error("cannot open " .. tostring(path)
                      .. ": FindFirstFileA failed (GetLastError="
                      .. tonumber(K.GetLastError()) .. ")", 2)
            end

            local first  = true
            local closed = false

            -- Iterator. Frees the Win32 search handle once exhausted so a caller
            -- that runs the loop to completion leaks nothing.
            return function()
                if closed then return nil end
                if first then
                    first = false
                    return ffi.string(fd.cFileName)
                end
                if K.FindNextFileA(h, fd) ~= 0 then
                    return ffi.string(fd.cFileName)
                end
                K.FindClose(h)
                closed = true
                return nil
            end
        end
    -- END --

    -- hs.fs.mkdir(dirname) -> true | nil, errmsg --
        function fs.mkdir(dirname)
            if K.CreateDirectoryA(dirname, nil) ~= 0 then
                return true
            end
            return nil, "mkdir failed (GetLastError=" .. tonumber(K.GetLastError()) .. ")"
        end
    -- END --

    -- hs.fs.rmdir(dirname) -> true | nil, errmsg --
        function fs.rmdir(dirname)
            if K.RemoveDirectoryA(dirname) ~= 0 then
                return true
            end
            return nil, "rmdir failed (GetLastError=" .. tonumber(K.GetLastError()) .. ")"
        end
    -- END --
-- END --

return fs
