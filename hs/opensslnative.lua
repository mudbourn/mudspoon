local ffi = require("ffi")

local M = {}

-- Windows CNG RSA PKCS#1 v1.5 SHA-256 signature check --
    local crypt32
    local bcrypt
    local loaded

    local X509_ASN_ENCODING = 1
    local X509_PUBLIC_KEY_INFO = ffi.cast("const char*", 8)
    local CRYPT_DECODE_ALLOC_FLAG = 0x8000
    local CRYPT_STRING_BASE64HEADER = 0
    local BCRYPT_PAD_PKCS1 = 2

    local SHA256_ALG = ffi.new("unsigned short[7]", { 83, 72, 65, 50, 53, 54, 0 })

    -- Loads crypt32 and bcrypt once. false when unavailable.
    local function load()
        if loaded ~= nil then return loaded end

        local okDef = pcall(ffi.cdef, [[
typedef struct { const unsigned short* pszAlgId; } mudossl_PKCS1_PADDING;
int CryptStringToBinaryA(const char*, unsigned long, unsigned long, uint8_t*, unsigned long*, unsigned long*, unsigned long*);
int CryptDecodeObjectEx(unsigned long, const char*, const uint8_t*, unsigned long, unsigned long, void*, void*, unsigned long*);
int CryptImportPublicKeyInfoEx2(unsigned long, void*, unsigned long, void*, void**);
void* LocalFree(void*);
int BCryptVerifySignature(void*, void*, uint8_t*, unsigned long, uint8_t*, unsigned long, unsigned long);
int BCryptDestroyKey(void*);
]])
        local okC, c = pcall(ffi.load, "crypt32")
        local okB, b = pcall(ffi.load, "bcrypt")

        if not (okDef and okC and okB) then
            loaded = false
            return false
        end

        crypt32 = c
        bcrypt = b
        loaded = true
        return true
    end

    -- PEM public key text to DER bytes, or nil
    local function pemToDer(pem)
        local cb = ffi.new("unsigned long[1]")
        if crypt32.CryptStringToBinaryA(pem, #pem, CRYPT_STRING_BASE64HEADER, nil, cb, nil, nil) == 0 then
            return nil
        end

        local buf = ffi.new("uint8_t[?]", cb[0])
        if crypt32.CryptStringToBinaryA(pem, #pem, CRYPT_STRING_BASE64HEADER, buf, cb, nil, nil) == 0 then
            return nil
        end

        return buf, cb[0]
    end

    -- A BCrypt key handle for a SubjectPublicKeyInfo PEM, or nil
    local function importKey(pem)
        local der, derLen = pemToDer(pem)
        if not der then return nil end

        local info = ffi.new("void*[1]")
        local infoLen = ffi.new("unsigned long[1]")
        if crypt32.CryptDecodeObjectEx(X509_ASN_ENCODING, X509_PUBLIC_KEY_INFO, der, derLen,
            CRYPT_DECODE_ALLOC_FLAG, nil, info, infoLen) == 0 then
            return nil
        end

        local key = ffi.new("void*[1]")
        local ok = crypt32.CryptImportPublicKeyInfoEx2(X509_ASN_ENCODING, info[0], 0, nil, key) ~= 0
        ffi.C.LocalFree(info[0])

        if not ok then return nil end
        return key[0]
    end

    -- Hex digest to raw bytes
    local function hexToBytes(hex)
        local n = #hex / 2
        local buf = ffi.new("uint8_t[?]", n)

        for i = 0, n - 1 do
            buf[i] = tonumber(hex:sub(i * 2 + 1, i * 2 + 2), 16)
        end

        return buf, n
    end

    -- True when CNG loaded
    function M.available()
        return load()
    end

    -- true or false for a checked signature, nil when the key or CNG is unusable
    function M.verifySha256(pem, signature, hexDigest)
        if not load() then return nil end

        local key = importKey(pem)
        if not key then return nil end

        local digest, digestLen = hexToBytes(hexDigest)
        local pad = ffi.new("mudossl_PKCS1_PADDING")
        pad.pszAlgId = SHA256_ALG

        local sig = ffi.new("uint8_t[?]", #signature)
        ffi.copy(sig, signature, #signature)

        local status = bcrypt.BCryptVerifySignature(key, pad, digest, digestLen, sig, #signature, BCRYPT_PAD_PKCS1)
        bcrypt.BCryptDestroyKey(key)

        return status == 0
    end
-- END --

return M
