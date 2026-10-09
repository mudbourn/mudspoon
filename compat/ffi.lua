local ffi = require("cffi")

local luaTonumber = tonumber

local luaCast = ffi.cast

-- Reads 64-bit cdata as a number and defers every other value to Lua
function tonumber(value, base)
    if base == nil and type(value) == "userdata" then
        return ffi.tonumber(value)
    end

    return luaTonumber(value, base)
end

-- Casts nil like a NULL pointer
function ffi.cast(ctype, value)
    if value == nil then
        return luaCast(ctype, ffi.nullptr)
    end

    return luaCast(ctype, value)
end

return ffi
