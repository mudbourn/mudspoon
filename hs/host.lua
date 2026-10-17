-- hs.host: facts about the machine and the operating system --

local ffi = require("ffi")

local host = require("hs.foundation")

-- Own FFI surface --
    for _, decl in ipairs({
        "typedef struct { DWORD dwOSVersionInfoSize; DWORD dwMajorVersion; DWORD dwMinorVersion; DWORD dwBuildNumber; DWORD dwPlatformId; WORD szCSDVersion[128]; } MS_OSVERSIONINFOW;",
        "LONG RtlGetVersion(MS_OSVERSIONINFOW*);",
        "BOOL GetComputerNameA(char*, DWORD*);"
    }) do
        pcall(ffi.cdef, decl)
    end
-- END --

local hostmod = {}

-- Reads major, minor and build from ntdll once
local version = (function()
    local info = ffi.new("MS_OSVERSIONINFOW")

    info.dwOSVersionInfoSize = ffi.sizeof(info)

    local ok = pcall(function() ffi.load("ntdll").RtlGetVersion(info) end)

    if not ok then
        return {
            major = 10,
            minor = 0,
            patch = 0
        }
    end

    return {
        major = tonumber(info.dwMajorVersion),
        minor = tonumber(info.dwMinorVersion),
        patch = tonumber(info.dwBuildNumber)
    }
end)()

-- Returns the OS version as major, minor and patch
function hostmod.operatingSystemVersion()
    return {
        major = version.major,
        minor = version.minor,
        patch = version.patch
    }
end

-- Returns the OS version in the "Version X.Y (Build N)" shape
function hostmod.operatingSystemVersionString()
    return string.format("Windows Version %d.%d (Build %d)", version.major, version.minor, version.patch)
end

-- Returns the computer name
function hostmod.localizedName()
    local buf = ffi.new("char[256]")
    local len = ffi.new("DWORD[1]", 256)

    if host.C.kernel32.GetComputerNameA(buf, len) == 0 then return os.getenv("COMPUTERNAME") or "" end

    return ffi.string(buf, len[0])
end

-- Returns the names this machine answers to
function hostmod.names()
    return { hostmod.localizedName() }
end

return hostmod
