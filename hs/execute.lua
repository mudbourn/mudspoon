-- hs.execute --
    -- hs.execute(command [, with_shell]) -> output, status, type, rc
    -- The module returns the callable directly.
    -- On Windows the command string is a POSIX command line. It runs under a real
    -- POSIX sh ($MUDSPOON_SH, default sh on PATH), and the plain file and hash
    -- commands mudscript emits run in process without spawning anything.
-- END --

local ffi = require("ffi")
local bit = require("bit")
local shims = require("hs.shims")

-- Platform and shell resolution --
    local IS_WINDOWS = package.config:sub(1, 1) == "\\"

    -- The POSIX shell command, possibly quoted and carrying arguments
    local function shExe()
        return os.getenv("MUDSPOON_SH") or "sh"
    end

    -- A writable temp dir
    local function tempDir()
        return os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "."
    end

    local MARKER = "__hammerspoon_rc__"
-- END --

-- Windows process spawn --
    local K
    local PM_NOREMOVE_SENDMESSAGE = 0x00400000
    local QS_SENDMESSAGE = 0x0040
    local INVALID_HANDLE = ffi.cast("void*", -1)
    local WAIT_POLL_MS = 5
    local READ_CHUNK = 65536

    if IS_WINDOWS then
        ffi.cdef[[
typedef struct { unsigned long nLength; void* lpSecurityDescriptor; int bInheritHandle; } mudexec_SA;

typedef struct {
    unsigned long cb;
    unsigned short* lpReserved;
    unsigned short* lpDesktop;
    unsigned short* lpTitle;
    unsigned long dwX;
    unsigned long dwY;
    unsigned long dwXSize;
    unsigned long dwYSize;
    unsigned long dwXCountChars;
    unsigned long dwYCountChars;
    unsigned long dwFillAttribute;
    unsigned long dwFlags;
    unsigned short wShowWindow;
    unsigned short cbReserved2;
    unsigned char* lpReserved2;
    void* hStdInput;
    void* hStdOutput;
    void* hStdError;
} mudexec_SI;

typedef struct { mudexec_SI StartupInfo; void* lpAttributeList; } mudexec_SIEX;

typedef struct { void* hProcess; void* hThread; unsigned long dwProcessId; unsigned long dwThreadId; } mudexec_PI;

int CreateProcessW(const unsigned short*, unsigned short*, mudexec_SA*, mudexec_SA*, int, unsigned long, void*, const unsigned short*, mudexec_SIEX*, mudexec_PI*);
int CreatePipe(void**, void**, mudexec_SA*, unsigned long);
int SetHandleInformation(void*, unsigned long, unsigned long);
void* CreateFileW(const unsigned short*, unsigned long, unsigned long, mudexec_SA*, unsigned long, unsigned long, void*);
int CloseHandle(void*);
int PeekNamedPipe(void*, void*, unsigned long, unsigned long*, unsigned long*, unsigned long*);
int ReadFile(void*, void*, unsigned long, unsigned long*, void*);
int GetExitCodeProcess(void*, unsigned long*);
void* GetStdHandle(unsigned long);
void* GetCurrentProcess(void);
int DuplicateHandle(void*, void*, void*, void**, unsigned long, int, unsigned long);
int InitializeProcThreadAttributeList(void*, unsigned long, unsigned long, size_t*);
int UpdateProcThreadAttribute(void*, unsigned long, uintptr_t, void*, size_t, void*, size_t*);
void DeleteProcThreadAttributeList(void*);
int MultiByteToWideChar(unsigned int, unsigned long, const char*, int, unsigned short*, int);
unsigned long WaitForSingleObject(void*, unsigned long);
]]
        K = ffi.load("kernel32")
    end

    -- Converts a narrow string to a NUL terminated UTF-16 buffer
    local function wide(s)
        local n = K.MultiByteToWideChar(0, 0, s, -1, nil, 0)
        local buf = ffi.new("unsigned short[?]", n)
        K.MultiByteToWideChar(0, 0, s, -1, buf, n)
        return buf
    end

    -- Dispatches sent messages so the low level hooks keep running during a wait
    local function waitDrain(proc, rd, host)
        local chunks = {}
        local avail = ffi.new("unsigned long[1]")
        local got = ffi.new("unsigned long[1]")
        local buf = ffi.new("uint8_t[?]", READ_CHUNK)
        local handles = ffi.new("void*[1]", proc)
        local msg = host and ffi.new("MSG")
        local U = host and host.C.user32

        local function drain()
            while K.PeekNamedPipe(rd, nil, 0, nil, avail, nil) ~= 0 and avail[0] > 0 do
                local want = math.min(tonumber(avail[0]), READ_CHUNK)
                if K.ReadFile(rd, buf, want, got, nil) == 0 or got[0] == 0 then break end
                chunks[#chunks + 1] = ffi.string(buf, got[0])
            end
        end

        while true do
            drain()

            local r
            if U then
                r = U.MsgWaitForMultipleObjects(1, handles, 0, WAIT_POLL_MS, QS_SENDMESSAGE)
                U.PeekMessageA(msg, nil, 0, 0, PM_NOREMOVE_SENDMESSAGE)
            else
                r = K.WaitForSingleObject(proc, WAIT_POLL_MS) == 0 and 0 or 258
            end

            if r == 0 then
                drain()
                break
            end
        end

        return table.concat(chunks)
    end

    -- The wait loop calls back into Lua hooks, so it must stay interpreted
    jit.off(waitDrain)

    -- Runs a command line with stdout piped back and returns output, exit code.
    -- Only the three std handles are inherited. nil, reason on a spawn failure.
    local function spawnCapture(cmdline)
        local okHost, host = pcall(require, "hs.foundation")
        if not okHost then host = nil end

        local sa = ffi.new("mudexec_SA")
        sa.nLength = ffi.sizeof("mudexec_SA")
        sa.bInheritHandle = 1

        local rd = ffi.new("void*[1]")
        local wr = ffi.new("void*[1]")
        if K.CreatePipe(rd, wr, sa, 1048576) == 0 then return nil, "CreatePipe failed" end
        K.SetHandleInformation(rd[0], 1, 0)

        local nul = K.CreateFileW(wide("NUL"), 0xC0000000, 3, sa, 3, 0, nil)
        local errH = nul
        local errDup = ffi.new("void*[1]")
        local stdErr = K.GetStdHandle(0xFFFFFFF4)
        local ownsErr = false

        if stdErr ~= nil and stdErr ~= INVALID_HANDLE then
            local me = K.GetCurrentProcess()
            if K.DuplicateHandle(me, stdErr, me, errDup, 0, 1, 2) ~= 0 then
                errH = errDup[0]
                ownsErr = true
            end
        end

        local inherit = {
            nul,
            wr[0]
        }
        if ownsErr then inherit[#inherit + 1] = errH end

        local sz = ffi.new("size_t[1]")
        K.InitializeProcThreadAttributeList(nil, 1, 0, sz)
        local attr = ffi.new("uint8_t[?]", tonumber(sz[0]))
        K.InitializeProcThreadAttributeList(attr, 1, 0, sz)

        local list = ffi.new("void*[?]", #inherit)
        for i, h in ipairs(inherit) do list[i - 1] = h end
        K.UpdateProcThreadAttribute(attr, 0, 0x20002, list, #inherit * ffi.sizeof("void*"), nil, nil)

        local si = ffi.new("mudexec_SIEX")
        si.StartupInfo.cb = ffi.sizeof("mudexec_SIEX")
        si.StartupInfo.dwFlags = 0x100
        si.StartupInfo.hStdInput = nul
        si.StartupInfo.hStdOutput = wr[0]
        si.StartupInfo.hStdError = errH
        si.lpAttributeList = attr

        local pi = ffi.new("mudexec_PI")
        local ok = K.CreateProcessW(nil, wide(cmdline), nil, nil, 1, 0x08080000, nil, nil, si, pi)

        K.CloseHandle(wr[0])
        K.CloseHandle(nul)
        if ownsErr then K.CloseHandle(errH) end
        K.DeleteProcThreadAttributeList(attr)

        if ok == 0 then
            K.CloseHandle(rd[0])
            return nil, "CreateProcessW failed"
        end

        K.CloseHandle(pi.hThread)

        if host then host.beginSyncWait() end
        local okWait, out = pcall(waitDrain, pi.hProcess, rd[0], host)
        if host then host.endSyncWait() end

        local code = ffi.new("unsigned long[1]")
        K.GetExitCodeProcess(pi.hProcess, code)
        K.CloseHandle(pi.hProcess)
        K.CloseHandle(rd[0])

        if not okWait then error(out, 0) end

        return (out:gsub("\r\n", "\n")), tonumber(code[0])
    end
-- END --

-- Shell availability --
    local shState

    -- True when the POSIX shell runs, warning once when it does not
    local function shAvailable()
        if shState ~= nil then return shState end

        local probe = spawnCapture(shExe() .. ' -c "echo __MSH_OK__"') or ""
        shState = probe:find("__MSH_OK__", 1, true) ~= nil

        if not shState then
            io.stderr:write("[hs.execute] no POSIX shell found (MUDSPOON_SH=" .. shExe()
                .. "). Shelled calls will no-op until one exists. "
                .. "Install git-for-Windows or busybox-w64, or set MUDSPOON_SH to an sh.exe.\n")
        end

        return shState
    end

    -- Writes the command to a temp script and runs it under sh. out, nil, ok
    local function runViaSh(command)
        if not shAvailable() then return nil, "no sh" end

        local path = ("%s/hammerspoon_exec_%d_%d.sh")
            :format(tempDir():gsub("[/\\]+$", ""), os.time(), math.random(1, 1e9))

        local f, ferr = io.open(path, "wb")
        if not f then return nil, ferr end

        f:write(command, "\necho ", MARKER, "=$?\n")
        f:close()

        local out, rc = spawnCapture(shExe() .. ' "' .. path .. '"')
        os.remove(path)

        if not out then return nil, rc end

        return out, nil, rc == 0 or nil
    end
-- END --

-- SHA-256 --
    local bcrypt
    local bcryptAlg

    -- Loads bcrypt once and opens the SHA-256 provider. nil when unavailable.
    local function sha256Provider()
        if bcryptAlg ~= nil then return bcryptAlg or nil end

        local ok = pcall(ffi.cdef, [[
int BCryptOpenAlgorithmProvider(void**, const unsigned short*, const unsigned short*, unsigned long);
int BCryptCreateHash(void*, void**, uint8_t*, unsigned long, uint8_t*, unsigned long, unsigned long);
int BCryptHashData(void*, const uint8_t*, unsigned long, unsigned long);
int BCryptFinishHash(void*, uint8_t*, unsigned long, unsigned long);
int BCryptDestroyHash(void*);
]])
        local okLoad, lib = pcall(ffi.load, "bcrypt")
        if not (ok and okLoad) then
            bcryptAlg = false
            return nil
        end

        bcrypt = lib
        local h = ffi.new("void*[1]")
        if bcrypt.BCryptOpenAlgorithmProvider(h, wide("SHA256"), nil, 0) ~= 0 then
            bcryptAlg = false
            return nil
        end

        bcryptAlg = h[0]
        return bcryptAlg
    end

    -- A streaming hasher: returns update(str) and finish() -> lowercase hex
    local function sha256Hasher()
        local alg = sha256Provider()
        if not alg then return nil end

        local hh = ffi.new("void*[1]")
        if bcrypt.BCryptCreateHash(alg, hh, nil, 0, nil, 0, 0) ~= 0 then return nil end

        local handle = hh[0]

        local function update(s)
            return bcrypt.BCryptHashData(handle, s, #s, 0) == 0
        end

        local function finish()
            local digest = ffi.new("uint8_t[32]")
            local ok = bcrypt.BCryptFinishHash(handle, digest, 32, 0) == 0
            bcrypt.BCryptDestroyHash(handle)
            if not ok then return nil end

            local hex = {}
            for i = 0, 31 do hex[#hex + 1] = ("%02x"):format(digest[i]) end
            return table.concat(hex)
        end

        return update, finish
    end

    -- Hex SHA-256 of a string, or nil
    local function sha256String(s)
        local update, finish = sha256Hasher()
        if not update then return nil end
        if not update(s) then return nil end
        return finish()
    end

    -- Hex SHA-256 of a file's bytes, or nil when it cannot be read
    local function sha256File(path)
        local f = io.open(path, "rb")
        if not f then return nil end

        local update, finish = sha256Hasher()
        if not update then
            f:close()
            return nil
        end

        while true do
            local chunk = f:read(262144)
            if not chunk then break end
            if not update(chunk) then
                f:close()
                return nil
            end
        end

        f:close()
        return finish()
    end
-- END --

-- Base64 decode --
    local B64 = {}
    do
        local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        for i = 1, #alphabet do B64[alphabet:byte(i)] = i - 1 end
    end

    -- Decodes canonical padded base64 (whitespace ignored). nil on anything else.
    local function base64Decode(text)
        local s = text:gsub("%s+", "")
        if s == "" or #s % 4 ~= 0 then return nil end
        if s:find("=", 1, true) and not s:find("^[^=]+=?=?$") then return nil end

        local out = {}
        local n = #s

        for i = 1, n, 4 do
            local c = { s:byte(i, i + 3) }
            local pad = 0
            local v = {}

            for k = 1, 4 do
                if c[k] == 61 then
                    if i + 3 < n then return nil end
                    pad = pad + 1
                    v[k] = 0
                else
                    if pad > 0 then return nil end
                    v[k] = B64[c[k]]
                    if v[k] == nil then return nil end
                end
            end

            local word = bit.bor(bit.lshift(v[1], 18), bit.lshift(v[2], 12), bit.lshift(v[3], 6), v[4])
            local bytes = string.char(bit.band(bit.rshift(word, 16), 255), bit.band(bit.rshift(word, 8), 255), bit.band(word, 255))
            out[#out + 1] = bytes:sub(1, 3 - pad)
        end

        return table.concat(out)
    end
-- END --

-- Native command fast path (Windows only) --
    -- Runs the plain file and hash commands mudscript emits in process. Only the
    -- exact command shapes are matched. Anything else returns nil and takes the
    -- real shell.

    -- Splits a command into argv, honouring POSIX single quotes and the '\'' idiom
    local function argvOf(command)
        local toks = {}
        local cur = {}
        local has = false
        local i = 1
        local n = #command

        while i <= n do
            local c = command:sub(i, i)

            if c == "'" then
                has = true
                local j = command:find("'", i + 1, true)
                if not j then return nil end
                cur[#cur + 1] = command:sub(i + 1, j - 1)
                i = j + 1
            elseif c == "\\" then
                has = true
                cur[#cur + 1] = command:sub(i + 1, i + 1)
                i = i + 2
            elseif c == " " or c == "\t" then
                if has then
                    toks[#toks + 1] = table.concat(cur)
                    cur = {}
                    has = false
                end
                i = i + 1
            else
                has = true
                cur[#cur + 1] = c
                i = i + 1
            end
        end

        if has then toks[#toks + 1] = table.concat(cur) end
        return toks
    end

    local function argvIsPlain(argv)
        for _, t in ipairs(argv) do
            if t:find("[|&<>;$`*?]") then return false end
        end
        return true
    end

    -- Decodes one single-quoted word made only of quoted runs joined by \'.
    -- nil when the text is anything else.
    local function quotedWord(text)
        local parts = {}
        local i = 1
        local n = #text

        while true do
            if text:sub(i, i) ~= "'" then return nil end

            local j = text:find("'", i + 1, true)
            if not j then return nil end

            parts[#parts + 1] = text:sub(i + 1, j - 1)
            i = j + 1

            if i > n then return table.concat(parts) end

            if text:sub(i, i + 1) ~= "\\'" then return nil end

            parts[#parts + 1] = "'"
            i = i + 2
        end
    end

    -- A path the native hash can print byte for byte as sh tools would
    local function plainName(name)
        return not name:find("[^\32-\126]") and not name:find("\\", 1, true)
    end

    local function isDrivePath(path)
        return path:match("^%a:[/\\]") ~= nil
    end

    local function nativeMkdirP(dir)
        local fs = require("hs.fs")
        local acc = nil

        for part in dir:gsub("\\", "/"):gmatch("[^/]+") do
            acc = acc and (acc .. "/" .. part) or part
            if not (acc:match("^%a:$")) then
                pcall(function() fs.mkdir(acc) end)
            end
        end

        return true
    end

    local function nativeCopyFile(src, dest)
        local fin = io.open(src, "rb")
        if not fin then return false end

        local fout = io.open(dest, "wb")
        if not fout then
            fin:close()
            return false
        end

        while true do
            local chunk = fin:read(1024 * 256)
            if not chunk then break end
            fout:write(chunk)
        end

        fin:close()
        fout:close()
        return true
    end

    local function nativeRemoveTree(path)
        local fs = require("hs.fs")
        local attr = fs.attributes(path)
        if not attr then return true end

        if attr.mode == "directory" then
            local it, dobj = fs.dir(path)
            local names = {}
            for name in it do
                if name ~= "." and name ~= ".." then names[#names + 1] = name end
            end
            if dobj then dobj:close() end

            for _, name in ipairs(names) do
                nativeRemoveTree(path .. "/" .. name)
            end

            pcall(function() fs.rmdir(path) end)
            return true
        end

        os.remove(path)
        return true
    end

    -- Lists files under baseDir as ./rel lines, dropping .DS_Store and, when
    -- dropBak, *.bak
    local function nativeFind(baseDir, dropBak, out, prefix)
        local fs = require("hs.fs")
        local it, dobj = fs.dir(baseDir)
        local names = {}
        for name in it do
            if name ~= "." and name ~= ".." then names[#names + 1] = name end
        end
        if dobj then dobj:close() end

        for _, name in ipairs(names) do
            local full = baseDir .. "/" .. name
            local rel = prefix .. name
            local attr = fs.attributes(full)

            if attr and attr.mode == "directory" then
                nativeFind(full, dropBak, out, rel .. "/")
            elseif attr then
                local skip = (name == ".DS_Store") or (dropBak and name:match("%.bak$"))
                if not skip then out[#out + 1] = "./" .. rel end
            end
        end

        return out
    end

    -- Collects the files the tree hash covers as rel paths. false when a name is
    -- not safe to hash natively.
    local function treeFiles(fs, baseDir, prefix, out)
        local it, dobj = fs.dir(baseDir)
        if not it then return false end

        local names = {}
        for name in it do
            if name ~= "." and name ~= ".." then names[#names + 1] = name end
        end
        if dobj then dobj:close() end

        for _, name in ipairs(names) do
            local attr = fs.attributes(baseDir .. "/" .. name)
            if not attr then return false end

            if attr.mode == "directory" then
                if not (prefix == "" and name == "__MACOSX") then
                    if not treeFiles(fs, baseDir .. "/" .. name, prefix .. name .. "/", out) then
                        return false
                    end
                end
            elseif name ~= ".DS_Store" and name:sub(1, 2) ~= "._" then
                if not plainName(name) then return false end
                out[#out + 1] = "./" .. prefix .. name
            end
        end

        return true
    end

    local HASH_TOOLS = {
        ["shasum -a 256"] = true,
        ["sha256sum"] = true,
    }

    local TREE_HASH_PATTERN = "^cd (.-) && find %. %-type f ! %-name '%.DS_Store' "
        .. "! %-name '%._%*' ! %-path '%./__MACOSX/%*' "
        .. "%-exec (.-) {} %+ 2>/dev/null | LC_ALL=C sort %-k2 | (.-)$"

    -- The sha256sum of the sorted per file listing of a tree, as sh prints it
    local function nativeTreeHash(command, fs)
        local quotedDir, tool, tool2 = command:match(TREE_HASH_PATTERN)
        if not quotedDir or tool ~= tool2 or not HASH_TOOLS[tool] then return nil end

        local dir = quotedWord(quotedDir)
        if not dir or not isDrivePath(dir) then return nil end

        local attr = fs.attributes(dir)
        if not attr or attr.mode ~= "directory" then return nil end

        local rels = {}
        if not treeFiles(fs, dir, "", rels) then return nil end
        table.sort(rels)

        local lines = {}
        for _, rel in ipairs(rels) do
            local h = sha256File(dir .. "/" .. rel:sub(3))
            if not h then return nil end
            lines[#lines + 1] = h .. " *" .. rel .. "\n"
        end

        local final = sha256String(table.concat(lines))
        if not final then return nil end

        return final .. " *-\n", 0
    end

    -- <hashtool> 'FILE' 2>/dev/null
    local function nativeFileHash(command, fs)
        local tool, rest
        for name in pairs(HASH_TOOLS) do
            local prefix = name .. " "
            if command:sub(1, #prefix) == prefix then
                tool = name
                rest = command:sub(#prefix + 1)
            end
        end
        if not tool then return nil end

        local quoted = rest:match("^(.-) 2>/dev/null$")
        local path = quoted and quotedWord(quoted)
        if not path or not isDrivePath(path) or not plainName(path) then return nil end

        local attr = fs.attributes(path)
        if not attr then return "", 1 end
        if attr.mode ~= "file" then return nil end

        local h = sha256File(path)
        if not h then return nil end

        return h .. " *" .. path .. "\n", 0
    end

    -- openssl base64 -d -A -in 'X' -out 'Y' 2>/dev/null
    local function nativeBase64(command)
        local inQ, outQ = command:match("^openssl base64 %-d %-A %-in (.-) %-out (.-) 2>/dev/null$")
        if not inQ then return nil end

        local inPath = quotedWord(inQ)
        local outPath = quotedWord(outQ)
        if not inPath or not outPath or not isDrivePath(inPath) or not isDrivePath(outPath) then
            return nil
        end

        local fin = io.open(inPath, "rb")
        if not fin then return nil end

        local text = fin:read("*a")
        fin:close()

        local bytes = text and base64Decode(text)
        if not bytes then return nil end

        local fout = io.open(outPath, "wb")
        if not fout then return nil end

        fout:write(bytes)
        fout:close()

        return "", 0
    end

    -- base64 -D -i 'X' -o 'Y'
    local function nativeBase64Mac(command)
        local argv = command:match("^base64 %-D %-i ") and argvOf(command)
        if not argv or #argv ~= 6 or argv[5] ~= "-o" then return nil end

        local inPath = argv[4]
        local outPath = argv[6]
        if not isDrivePath(inPath) or not isDrivePath(outPath) then return nil end

        local fin = io.open(inPath, "rb")
        if not fin then return nil end

        local text = fin:read("*a")
        fin:close()

        local bytes = text and base64Decode(text)
        if not bytes then return nil end

        local fout = io.open(outPath, "wb")
        if not fout then return nil end

        fout:write(bytes)
        fout:close()

        return "", 0
    end

    -- openssl version 2>/dev/null
    local function nativeOpensslVersion(command)
        if command ~= "openssl version 2>/dev/null" then return nil end

        local okMod, ossl = pcall(require, "hs.opensslnative")
        if not okMod or not ossl.available() then return nil end

        return "OpenSSL 3.0.0 (mudspoon native)\n", 0
    end

    -- openssl dgst -sha256 -verify 'KEY' -signature 'SIG' 'MSG' 2>&1
    local function nativeOpensslVerify(command)
        local body = command:match("^(openssl dgst %-sha256 %-verify .-) 2>&1$")
        local argv = body and argvOf(body)
        if not argv or #argv ~= 8 or argv[6] ~= "-signature" then return nil end

        local keyPath, sigPath, msgPath = argv[5], argv[7], argv[8]
        if not (isDrivePath(keyPath) and isDrivePath(sigPath) and isDrivePath(msgPath)) then
            return nil
        end

        local okMod, ossl = pcall(require, "hs.opensslnative")
        if not okMod then return nil end

        local kf = io.open(keyPath, "rb")
        local sf = io.open(sigPath, "rb")
        local pem = kf and kf:read("*a")
        local sig = sf and sf:read("*a")
        if kf then kf:close() end
        if sf then sf:close() end
        if not pem or not sig then return nil end

        local digest = sha256File(msgPath)
        if not digest then return nil end

        local verified = ossl.verifySha256(pem, sig, digest)
        if verified == nil then return nil end

        if verified then return "Verified OK\n", 0 end

        return "Verification failure\n", 1
    end

    local HASH_PROBE = "command -v shasum >/dev/null 2>&1 && printf '%s' 'shasum -a 256' || "
        .. "(command -v sha256sum >/dev/null 2>&1 && printf sha256sum || printf '')"

    -- Returns out, rc on a matched shape and nil to fall back to the shell
    local function nativeRun(command)
        local ok, fs = pcall(require, "hs.fs")
        if not ok or not fs then return nil end

        if command:match("^/sbin/md5 ") then return "", 127 end

        if command == HASH_PROBE then return "sha256sum", 0 end

        if command == "/usr/bin/uname -m 2>/dev/null" then
            local arch = os.getenv("PROCESSOR_ARCHITECTURE") or ""
            return (arch:upper() == "ARM64" and "aarch64" or "x86_64") .. "\n", 0
        end

        local treeOut, treeRc = nativeTreeHash(command, fs)
        if treeOut then return treeOut, treeRc end

        local fileOut, fileRc = nativeFileHash(command, fs)
        if fileOut then return fileOut, fileRc end

        local b64Out, b64Rc = nativeBase64(command)
        if b64Out then return b64Out, b64Rc end

        local macOut, macRc = nativeBase64Mac(command)
        if macOut then return macOut, macRc end

        local verOut, verRc = nativeOpensslVersion(command)
        if verOut then return verOut, verRc end

        local sigOut, sigRc = nativeOpensslVerify(command)
        if sigOut then return sigOut, sigRc end

        local quotedDir, mid = command:match(
            "^cd (.-) && find %. %-type f ! %-name '%.DS_Store'(.-) 2>/dev/null$")
        if quotedDir and (mid == "" or mid == " ! -name '*.bak'") then
            local argv = argvOf(quotedDir)
            if argv and argv[1] and not argv[2] then
                local dropBak = mid ~= ""
                local lines = nativeFind(argv[1], dropBak, {}, "")
                if #lines == 0 then return "", 0 end
                return table.concat(lines, "\n") .. "\n", 0
            end
        end

        local statOut, statRc = shims.statCommand(command)
        if statOut then return statOut, statRc end

        local openArgv = shims.openArgv(command)
        if openArgv then return "", shims.open(openArgv) end

        local argv = argvOf(command)
        if not argv or not argvIsPlain(argv) then return nil end
        local a1, a2, a3, a4 = argv[1], argv[2], argv[3], argv[4]

        if a1 == "mkdir" and a2 == "-p" and a3 and not a4 then
            nativeMkdirP(a3)
            return "", 0
        end

        if a1 == "/bin/cp" and a2 and a3 and not a4 then
            return "", nativeCopyFile(a2, a3) and 0 or 1
        end

        if a1 == "/bin/rm" and (a2 == "-rf" or a2 == "-f") and a3 and not a4 then
            nativeRemoveTree(a3)
            return "", 0
        end

        if a1 == "/bin/mv" and a2 and a3 and not a4 then
            if os.rename(a2, a3) then return "", 0 end
            return nil
        end

        return nil
    end
-- END --

-- execute --
    -- with_shell defaults to true. With it a POSIX shell runs the command and an
    -- exit code marker is stripped from the output. with_shell=false runs the raw
    -- string through the platform popen shell with no marker.
    local function execute(command, with_shell)
        if with_shell == nil then with_shell = true end

        if with_shell and IS_WINDOWS then
            local out, rc = nativeRun(command)
            if out ~= nil then
                return out, (rc == 0) or nil, "exit", rc
            end
        end

        local out, ok

        if with_shell and IS_WINDOWS then
            local rout, _, rok = runViaSh(shims.zipCommand(command) or shims.unzipListCommand(command) or command)
            if rout == nil then return "", nil, "exit", -1 end
            out, ok = rout, rok
        else
            local toRun = command
            if with_shell then
                toRun = command .. " ; echo " .. MARKER .. "=$?"
            end

            local handle = io.popen(toRun, "r")
            if not handle then return "", nil, "exit", -1 end

            out = handle:read("*a") or ""
            ok = handle:close()
        end

        local status, typ, rc

        if with_shell then
            local code
            for line in out:gmatch("[^\r\n]+") do
                local m = line:match("^" .. MARKER .. "=(%-?%d+)$")
                if m then code = tonumber(m) end
            end

            out = out:gsub(MARKER .. "=[^\r\n]*\r?\n?", "")

            if code then
                rc = code
                typ = "exit"
                status = (code == 0) or nil
            end
        end

        if status == nil and rc == nil then
            typ = "exit"
            status = ok and true or nil
            rc = ok and 0 or 1
        end

        return out, status, typ, rc
    end
-- END --

return execute
