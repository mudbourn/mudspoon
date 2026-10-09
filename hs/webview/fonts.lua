-- hs.webview.fonts --
    -- Builds a <style> of data URI @font-face rules for every font in <configdir>/ui/fonts
-- END --

local fonts = {}

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local cache = {
    signature = nil,
    tag = "",
}

-- Binary helpers --
    -- Big endian unsigned 16 bit read at a 0 based offset
    local function u16(data, at)
        local a, b = data:byte(at + 1, at + 2)
        return (a or 0) * 256 + (b or 0)
    end

    -- Big endian unsigned 32 bit read at a 0 based offset
    local function u32(data, at)
        return u16(data, at) * 65536 + u16(data, at + 2)
    end

    -- Base64 encoding of a binary string
    local function base64(data)
        local out = {}

        for i = 1, #data, 3 do
            local a, b, c = data:byte(i, i + 2)

            local n = ((a << 16) | ((b or 0) << 8) | (c or 0))

            local s1 = ((n >> 18) & 63) + 1

            local s2 = ((n >> 12) & 63) + 1

            local s3 = ((n >> 6) & 63) + 1

            local s4 = (n & 63) + 1

            out[#out + 1] = B64:sub(s1, s1)
                .. B64:sub(s2, s2)
                .. (b and B64:sub(s3, s3) or "=")
                .. (c and B64:sub(s4, s4) or "=")
        end

        return table.concat(out)
    end
-- END --

-- Font table parsing --
    -- Offset of a named sfnt table, or nil
    local function findTable(data, tag)
        local count = u16(data, 4)

        for i = 0, count - 1 do
            local rec = 12 + i * 16

            if data:sub(rec + 1, rec + 4) == tag then
                return u32(data, rec + 8)
            end
        end
    end

    -- Windows UTF-16BE name record decoded to ASCII, preferring a given name id
    local function readName(data, nameId)
        local base = findTable(data, "name")
        if not base then return nil end

        local count = u16(data, base + 2)

        local strings = base + u16(data, base + 4)

        for i = 0, count - 1 do
            local rec = base + 6 + i * 12

            if u16(data, rec) == 3 and u16(data, rec + 6) == nameId then
                local len = u16(data, rec + 8)

                local off = strings + u16(data, rec + 10)

                local chars = {}

                for j = 0, len - 2, 2 do
                    local code = u16(data, off + j)

                    chars[#chars + 1] = code < 128 and string.char(code) or "?"
                end

                return table.concat(chars)
            end
        end
    end

    -- Family, weight and italic flag of a font, falling back to the file name
    local function describe(data, file)
        local family = readName(data, 16) or readName(data, 1)

        local weight = 400

        local italic = false

        local os2 = findTable(data, "OS/2")

        if os2 then
            weight = u16(data, os2 + 4)

            italic = (u16(data, os2 + 62) & 1) == 1
        end

        return {
            family = family or file:gsub("%.[^%.]+$", ""),
            weight = weight,
            italic = italic,
        }
    end
-- END --

-- Style tag --
    -- MIME type of a font file extension
    local MIME = {
        ttf = "font/ttf",
        otf = "font/otf",
        woff = "font/woff",
        woff2 = "font/woff2",
    }

    -- One @font-face rule
    local function rule(family, weight, italic, mime, b64)
        return '@font-face{font-family:"' .. family:gsub('"', "")
            .. '";font-weight:' .. weight
            .. ";font-style:" .. (italic and "italic" or "normal")
            .. ";font-display:block;src:url(data:" .. mime .. ";base64," .. b64 .. ");}"
    end

    -- Sorted font file names in a directory with their size and mtime signature
    local function listFonts(fs, dir)
        local files = {}

        local sig = {}

        for file in fs.dir(dir) do
            local ext = (file:match("%.([^%.]+)$") or ""):lower()

            if MIME[ext] then
                local attr = fs.attributes(dir .. "/" .. file) or {}

                files[#files + 1] = file

                sig[#sig + 1] = file .. ":" .. tostring(attr.size) .. ":" .. tostring(attr.modification)
            end
        end

        table.sort(files)

        table.sort(sig)

        return files, table.concat(sig, "|")
    end

    -- The <style> tag for the current ui/fonts directory, rebuilt only when its contents change
    function fonts.styleTag()
        local configdir = _G.hs and _G.hs.configdir
        if not configdir then return "" end

        local fs = require("hs.fs")

        local dir = configdir .. "/ui/fonts"

        if not fs.attributes(dir) then return "" end

        local files, signature = listFonts(fs, dir)

        if signature == cache.signature then return cache.tag end

        local rules = {}

        for _, file in ipairs(files) do
            local fin = io.open(dir .. "/" .. file, "rb")

            if fin then
                local data = fin:read("*all")

                fin:close()

                local ext = file:match("%.([^%.]+)$"):lower()

                local b64 = base64(data)

                local info = (ext == "ttf" or ext == "otf") and describe(data, file) or {
                    family = file:gsub("%.[^%.]+$", ""),
                    weight = 400,
                    italic = false,
                }

                local stem = file:gsub("%.[^%.]+$", "")

                rules[#rules + 1] = rule(info.family, info.weight, info.italic, MIME[ext], b64)

                if stem ~= info.family then
                    rules[#rules + 1] = rule(stem, 400, false, MIME[ext], b64)
                end
            end
        end

        cache.signature = signature

        cache.tag = #rules > 0 and ("<style id=\"_mudspoon-fonts\">" .. table.concat(rules) .. "</style>") or ""

        return cache.tag
    end
-- END --

return fonts
