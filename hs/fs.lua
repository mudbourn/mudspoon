-- hs.fs over kernel32

local ffi = require("ffi")

-- Foundation: shared types + the single loaded kernel32 handle. --
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
    local INVALID_HANDLE_VALUE     = ffi.cast("HANDLE", -1)

    local FILETIME_EPOCH_DELTA     = 116444736000000000
-- END --

-- Helpers --
    -- Folds a FILETIME into unix epoch seconds, 0 for a zero FILETIME
    local function fileTimeToEpoch(ft)
        local ticks = (ft.dwHighDateTime << 32) | ft.dwLowDateTime

        if ticks < FILETIME_EPOCH_DELTA then return 0 end

        return (ticks - FILETIME_EPOCH_DELTA) // 10000000
    end

    -- Combines the high and low size halves into one number
    local function fileSize(high, low)
        return (high << 32) | low
    end

    -- LFS-style string mode from Win32 attributes
    local function modeOf(attrs)
        if (attrs & FILE_ATTRIBUTE_DIRECTORY) ~= 0 then return "directory" end
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

    -- hs.fs.dir(path) -> iterFn, dirObj --
        -- LFS/Hammerspoon return TWO values: the iterator AND a directory object
        -- with a :close() method. `for name in hs.fs.dir(path) do ... end` uses the
        -- iterator (first value); callers that grab `local it, d = hs.fs.dir(p)` then
        -- call `d:close()` explicitly (mudscript's guardian does). Returning only the
        -- iterator makes that d nil and d:close() crash -- so both are returned.
        -- Yields every entry INCLUDING "." and ".."; raises if the path can't open.
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
            local function closeHandle()      -- idempotent: exhaustion and :close() both land here
                if not closed then K.FindClose(h); closed = true end
            end

            -- Iterator. Frees the Win32 search handle once exhausted so a caller
            -- that runs the loop to completion leaks nothing.
            local function iter()
                if closed then return nil end
                if first then
                    first = false
                    return ffi.string(fd.cFileName)
                end
                if K.FindNextFileA(h, fd) ~= 0 then
                    return ffi.string(fd.cFileName)
                end
                closeHandle()
                return nil
            end

            -- LFS-style directory object. :close() is safe to call any time (before
            -- or after exhaustion), matching LFS, so an early-exiting loop can free
            -- the handle without leaking.
            local dirObj = { close = function() closeHandle() end }

            return iter, dirObj
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
