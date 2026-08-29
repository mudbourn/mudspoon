-- hs.json  (leaf) --
    -- Hammerspoon's hs.json.encode / hs.json.decode over a self-contained
    -- pure-Lua codec. The consumer only ever encodes (compact and pretty) and
    -- decodes, so read/write file helpers are intentionally omitted.
    --
    -- Leaf: no Foundation, no FFI, no C module. Runs on plain LuaJIT. Keeping it
    -- dependency-free means config/state serialization works before any host
    -- machinery is up.
-- END --

local json = {}

-- Encoder --
    -- Array vs object: a table is an array only if every key is a contiguous
    -- integer 1..n. Everything else (including the empty table, matching
    -- Hammerspoon) is an object. nil values simply never appear, since Lua
    -- tables cannot hold them -- that lossiness is the documented HS behavior.
    local function isArray(t)
        local n = 0
        for k in pairs(t) do
            if type(k) ~= "number" or k % 1 ~= 0 or k < 1 then return false end
            if k > n then n = k end
        end
        for i = 1, n do
            if t[i] == nil then return false end  -- hole => object
        end
        return n > 0
    end

    -- JSON string escapes. `/` may stay literal (spec allows it), so we leave it
    -- to keep output readable and byte-stable. UTF-8 bytes pass through untouched;
    -- only quote, backslash, and C0 control chars must be escaped.
    local escapes = {
        ['"']  = '\\"',
        ['\\'] = '\\\\',
        ['\b'] = '\\b',
        ['\f'] = '\\f',
        ['\n'] = '\\n',
        ['\r'] = '\\r',
        ['\t'] = '\\t',
    }
    local function escapeStr(s)
        return '"' .. s:gsub('[%z\1-\31"\\]', function(c)
            return escapes[c] or string.format("\\u%04x", string.byte(c))
        end) .. '"'
    end

    -- Integers print without a trailing ".0"; other finite numbers use %.14g,
    -- enough to round-trip a double. JSON has no inf/nan, so reject them.
    local function encodeNumber(n)
        if n ~= n or n == math.huge or n == -math.huge then
            error("hs.json: cannot encode non-finite number", 0)
        end
        if n % 1 == 0 and math.abs(n) < 1e15 then
            return string.format("%d", n)
        end
        return string.format("%.14g", n)
    end

    -- gap: per-level indent for pretty mode (nil in compact mode).
    local encodeValue
    local function encodeValue_impl(v, pretty, depth)
        local t = type(v)
        if t == "string" then
            return escapeStr(v)
        elseif t == "number" then
            return encodeNumber(v)
        elseif t == "boolean" then
            return v and "true" or "false"
        elseif t == "table" then
            local nl, pad, pad2, sep, colon
            if pretty then
                pad   = ("  "):rep(depth)
                pad2  = ("  "):rep(depth + 1)
                nl    = "\n"
                sep   = ",\n"
                colon = ": "
            else
                pad, pad2, nl, sep, colon = "", "", "", ",", ":"
            end

            if isArray(v) then
                local parts = {}
                for i = 1, #v do
                    parts[i] = pad2 .. encodeValue(v[i], pretty, depth + 1)
                end
                if #parts == 0 then return "[]" end
                return "[" .. nl .. table.concat(parts, sep) .. nl .. pad .. "]"
            else
                -- Sort keys so output is deterministic (aids diffs/tests).
                local keys = {}
                for k in pairs(v) do
                    local kt = type(k)
                    if kt ~= "string" and kt ~= "number" then
                        error("hs.json: object key must be string or number", 0)
                    end
                    keys[#keys + 1] = k
                end
                table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

                local parts = {}
                for _, k in ipairs(keys) do
                    parts[#parts + 1] = pad2 .. escapeStr(tostring(k)) ..
                        colon .. encodeValue(v[k], pretty, depth + 1)
                end
                if #parts == 0 then return "{}" end
                return "{" .. nl .. table.concat(parts, sep) .. nl .. pad .. "}"
            end
        elseif t == "nil" then
            return "null"
        elseif t == "cdata" then
            -- LuaJIT-only: a raw FFI number (int64/uint64/double cdata) reaches here
            -- when a Windows shim hands the config a number in cdata form -- Mac has a
            -- plain Lua number for the same value, so NSJSONSerialization never sees
            -- this case. Coerce numeric cdata to a Lua number so the payload encodes
            -- identically to Mac; without this, ONE such value anywhere in a state
            -- table threw and blanked the whole panel that carried it (e.g. the Settings/
            -- Tools/Appearance/Profiles hydration payload). Non-numeric cdata is still
            -- genuinely unencodable.
            local n = tonumber(v)
            if n then return encodeNumber(n) end
            error("hs.json: cannot encode non-numeric cdata value", 0)
        else
            error("hs.json: cannot encode value of type " .. t, 0)
        end
    end
    encodeValue = encodeValue_impl

    function json.encode(val, prettyprint)
        return encodeValue(val, prettyprint and true or false, 0)
    end
-- END --

-- Decoder --
    -- A small recursive-descent parser over the raw string with a running index.
    -- It never allocates a token stream; each helper consumes forward and returns
    -- the next position, so nesting cost is just Lua call depth.
    local decodeValue

    local function skipWhitespace(s, i)
        local _, j = s:find("^[ \t\r\n]*", i)
        return j + 1
    end

    -- Reverse of the encoder's escape table, plus \/ and \uXXXX.
    local unescapes = {
        ['"']  = '"',
        ['\\'] = '\\',
        ['/']  = '/',
        ['b']  = '\b',
        ['f']  = '\f',
        ['n']  = '\n',
        ['r']  = '\r',
        ['t']  = '\t',
    }

    -- Encode a Unicode code point as UTF-8 bytes (LuaJIT has no utf8 lib).
    local function utf8Encode(cp)
        if cp < 0x80 then
            return string.char(cp)
        elseif cp < 0x800 then
            return string.char(0xC0 + math.floor(cp / 0x40),
                               0x80 + cp % 0x40)
        else
            return string.char(0xE0 + math.floor(cp / 0x1000),
                               0x80 + math.floor(cp / 0x40) % 0x40,
                               0x80 + cp % 0x40)
        end
    end

    local function decodeString(s, i)
        -- s[i] is the opening quote.
        local buf, pos = {}, i + 1
        while true do
            local c = s:sub(pos, pos)
            if c == "" then error("hs.json: unterminated string", 0) end
            if c == '"' then
                return table.concat(buf), pos + 1
            elseif c == "\\" then
                local e = s:sub(pos + 1, pos + 1)
                if e == "u" then
                    local hex = s:sub(pos + 2, pos + 5)
                    if not hex:match("^%x%x%x%x$") then
                        error("hs.json: bad \\u escape", 0)
                    end
                    local cp = tonumber(hex, 16)
                    pos = pos + 6
                    -- Surrogate pair -> combine into one code point.
                    if cp >= 0xD800 and cp <= 0xDBFF and s:sub(pos, pos + 1) == "\\u" then
                        local lo = tonumber(s:sub(pos + 2, pos + 5), 16)
                        if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                            pos = pos + 6
                            -- 4-byte UTF-8 for astral planes.
                            buf[#buf + 1] = string.char(
                                0xF0 + math.floor(cp / 0x40000),
                                0x80 + math.floor(cp / 0x1000) % 0x40,
                                0x80 + math.floor(cp / 0x40) % 0x40,
                                0x80 + cp % 0x40)
                        else
                            buf[#buf + 1] = utf8Encode(cp)
                        end
                    else
                        buf[#buf + 1] = utf8Encode(cp)
                    end
                else
                    local u = unescapes[e]
                    if not u then error("hs.json: bad escape \\" .. e, 0) end
                    buf[#buf + 1] = u
                    pos = pos + 2
                end
            else
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
    end

    local function decodeNumber(s, i)
        local num = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
        if not num or num == "" then error("hs.json: invalid number", 0) end
        local n = tonumber(num)
        if not n then error("hs.json: invalid number '" .. num .. "'", 0) end
        return n, i + #num
    end

    local function decodeArray(s, i)
        local arr, pos = {}, skipWhitespace(s, i + 1)
        if s:sub(pos, pos) == "]" then return arr, pos + 1 end
        while true do
            local v
            v, pos = decodeValue(s, pos)
            arr[#arr + 1] = v
            pos = skipWhitespace(s, pos)
            local c = s:sub(pos, pos)
            if c == "]" then return arr, pos + 1 end
            if c ~= "," then error("hs.json: expected ',' or ']' in array", 0) end
            pos = skipWhitespace(s, pos + 1)
        end
    end

    local function decodeObject(s, i)
        local obj, pos = {}, skipWhitespace(s, i + 1)
        if s:sub(pos, pos) == "}" then return obj, pos + 1 end
        while true do
            if s:sub(pos, pos) ~= '"' then error("hs.json: expected string key", 0) end
            local key
            key, pos = decodeString(s, pos)
            pos = skipWhitespace(s, pos)
            if s:sub(pos, pos) ~= ":" then error("hs.json: expected ':' after key", 0) end
            local v
            v, pos = decodeValue(s, skipWhitespace(s, pos + 1))
            obj[key] = v
            pos = skipWhitespace(s, pos)
            local c = s:sub(pos, pos)
            if c == "}" then return obj, pos + 1 end
            if c ~= "," then error("hs.json: expected ',' or '}' in object", 0) end
            pos = skipWhitespace(s, pos + 1)
        end
    end

    -- Dispatch on the first non-space byte. Returns value, next-index.
    function decodeValue(s, i)
        i = skipWhitespace(s, i)
        local c = s:sub(i, i)
        if c == "{" then
            return decodeObject(s, i)
        elseif c == "[" then
            return decodeArray(s, i)
        elseif c == '"' then
            return decodeString(s, i)
        elseif c == "t" then
            if s:sub(i, i + 3) ~= "true" then error("hs.json: invalid literal", 0) end
            return true, i + 4
        elseif c == "f" then
            if s:sub(i, i + 4) ~= "false" then error("hs.json: invalid literal", 0) end
            return false, i + 5
        elseif c == "n" then
            if s:sub(i, i + 3) ~= "null" then error("hs.json: invalid literal", 0) end
            -- null -> nil; inside a table it just means the key is absent.
            return nil, i + 4
        elseif c:match("[%-%d]") then
            return decodeNumber(s, i)
        elseif c == "" then
            error("hs.json: unexpected end of input", 0)
        else
            error("hs.json: unexpected character '" .. c .. "'", 0)
        end
    end

    function json.decode(str)
        if type(str) ~= "string" then
            error("hs.json.decode: expected string", 0)
        end
        local value, pos = decodeValue(str, 1)
        pos = skipWhitespace(str, pos)
        if pos <= #str then
            error("hs.json: trailing garbage after value", 0)
        end
        return value
    end
-- END --

return json
