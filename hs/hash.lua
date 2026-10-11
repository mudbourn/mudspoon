-- hs.hash over the Windows CNG hash providers

local ffi = require("ffi")

local hash = {}

-- CNG --
    pcall(ffi.cdef, [[
int BCryptOpenAlgorithmProvider(void**, const unsigned short*, const unsigned short*, unsigned long);
int BCryptCreateHash(void*, void**, uint8_t*, unsigned long, uint8_t*, unsigned long, unsigned long);
int BCryptHashData(void*, const char*, unsigned long, unsigned long);
int BCryptFinishHash(void*, uint8_t*, unsigned long, unsigned long);
int BCryptDestroyHash(void*);
]])

    local okLoad, bcrypt = pcall(ffi.load, "bcrypt")

    -- HMAC flag for BCryptOpenAlgorithmProvider
    local BCRYPT_ALG_HANDLE_HMAC_FLAG = 0x8

    -- Digest length in bytes by CNG algorithm name
    local DIGEST_LEN = {
        MD5    = 16,
        SHA1   = 20,
        SHA256 = 32,
        SHA512 = 64,
    }

    -- Open providers keyed by algorithm name and HMAC flag
    local providers = {}

    -- A NUL terminated UTF-16 buffer for an ASCII string
    local function wideAscii(s)
        local buf = ffi.new("unsigned short[?]", #s + 1)

        for i = 1, #s do buf[i - 1] = s:byte(i) end

        return buf
    end

    -- The provider for an algorithm, or nil
    local function provider(alg, hmac)
        local key = alg .. (hmac and ":hmac" or "")

        if providers[key] ~= nil then return providers[key] or nil end

        local h = ffi.new("void*[1]")
        local flags = hmac and BCRYPT_ALG_HANDLE_HMAC_FLAG or 0

        if not okLoad or bcrypt.BCryptOpenAlgorithmProvider(h, wideAscii(alg), nil, flags) ~= 0 then
            providers[key] = false

            return nil
        end

        providers[key] = h[0]

        return h[0]
    end

    -- Raw digest of data under alg, keyed when secret is given, or nil
    local function digest(alg, data, secret)
        local prov = provider(alg, secret ~= nil)

        if not prov then return nil end

        local hh = ffi.new("void*[1]")
        local keyLen = secret and #secret or 0
        local keyBuf = secret and ffi.new("uint8_t[?]", keyLen + 1, secret) or nil

        if bcrypt.BCryptCreateHash(prov, hh, nil, 0, keyBuf, keyLen, 0) ~= 0 then return nil end

        local len = DIGEST_LEN[alg]
        local out = ffi.new("uint8_t[?]", len)
        local ok = bcrypt.BCryptHashData(hh[0], data, #data, 0) == 0
            and bcrypt.BCryptFinishHash(hh[0], out, len, 0) == 0

        bcrypt.BCryptDestroyHash(hh[0])

        if not ok then return nil end

        return ffi.string(out, len)
    end

    -- Lowercase hex of a byte string
    local function hex(raw)
        if not raw then return nil end

        return (raw:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
    end
-- END --

-- Public API --
    for name, alg in pairs({
        MD5    = "MD5",
        SHA1   = "SHA1",
        SHA256 = "SHA256",
        SHA512 = "SHA512",
    }) do
        hash[name] = function(data)
            return hex(digest(alg, tostring(data)))
        end

        hash["b" .. name] = function(data)
            return digest(alg, tostring(data))
        end

        hash["hmac" .. name] = function(secret, data)
            return hex(digest(alg, tostring(data), tostring(secret)))
        end

        hash["bhmac" .. name] = function(secret, data)
            return digest(alg, tostring(data), tostring(secret))
        end
    end
-- END --

return hash
