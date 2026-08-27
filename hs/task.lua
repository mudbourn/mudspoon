-- hs.task  (leaf, Foundation-backed) --
    -- Asynchronous subprocess, the async muscle mac/ leans on (curl downloads,
    -- shasum hashing, the gamepad reader). The slice mac/ actually uses:
    --   hs.task.new(path, doneFn)                       -- doneFn(exitCode, out, err)
    --   hs.task.new(path, doneFn, argsTable)            -- args as an array (no shell)
    --   hs.task.new(path, doneFn, streamFn)             -- streamFn(task, out, err)->bool
    --   task:start()   -> task (truthy) on launch, nil on failure
    --   task:terminate()
    -- The 4-arg form new(path, doneFn, streamFn, argsTable) is accepted too (hs parity).
    --
    -- WINDOWS ASYNC MODEL: mudspoon is one thread + one message pump, so we cannot
    -- block on the child. We launch via CreateProcessA with stdout/stderr redirected
    -- to inheritable temp files, then POLL WaitForSingleObject(h, 0) off the runloop
    -- (host.schedule). Temp files (not pipes) sidestep the classic pipe-buffer
    -- deadlock and let a streaming child's stdout be tailed incrementally with plain
    -- Lua file IO. On exit we read the files, fire doneFn(exitCode, stdout, stderr),
    -- and clean up. This reuses execute.lua's "spawn + capture to disk" spirit while
    -- staying non-blocking.
    --
    -- UNIX-PATH TRANSLATION: mac/ passes mac launch paths like "/usr/bin/curl".
    -- Those don't exist on Windows, so if the given path can't be opened we fall
    -- back to its BASENAME and let CreateProcess search PATH (curl.exe, shasum, ...).
    -- An absolute path that DOES exist (e.g. the gamepad binary on the rig) is used
    -- verbatim. RIG-UNVERIFIED: no Windows here to prove the PATH search.
-- END --

local host = require("hs.foundation")
local ffi  = host.ffi
local bit  = host.bit
local K    = host.C.kernel32

-- Process FFI (functions + structs NOT owned by Foundation) --
    -- Foundation owns HANDLE/DWORD/BOOL/WORD/BYTE/UINT/void*, so those are reused.
    -- STARTUPINFOA / PROCESS_INFORMATION / SECURITY_ATTRIBUTES are ours to declare
    -- (nothing else does). char* stands in for LPSTR to avoid a new typedef.
    ffi.cdef[[
typedef struct {
  DWORD  cb;            char*  lpReserved;  char*  lpDesktop;  char*  lpTitle;
  DWORD  dwX;           DWORD  dwY;         DWORD  dwXSize;    DWORD  dwYSize;
  DWORD  dwXCountChars; DWORD  dwYCountChars; DWORD dwFillAttribute;
  DWORD  dwFlags;       WORD   wShowWindow; WORD   cbReserved2; BYTE* lpReserved2;
  HANDLE hStdInput;     HANDLE hStdOutput;  HANDLE hStdError;
} STARTUPINFOA;

typedef struct {
  HANDLE hProcess; HANDLE hThread; DWORD dwProcessId; DWORD dwThreadId;
} PROCESS_INFORMATION;

typedef struct {
  DWORD nLength; void* lpSecurityDescriptor; BOOL bInheritHandle;
} SECURITY_ATTRIBUTES;

BOOL   CreateProcessA(const char*, char*, void*, void*, BOOL, DWORD,
                      void*, const char*, STARTUPINFOA*, PROCESS_INFORMATION*);
HANDLE CreateFileA(const char*, DWORD, DWORD, SECURITY_ATTRIBUTES*, DWORD, DWORD, HANDLE);
HANDLE GetStdHandle(DWORD);
DWORD  WaitForSingleObject(HANDLE, DWORD);
BOOL   GetExitCodeProcess(HANDLE, DWORD*);
BOOL   TerminateProcess(HANDLE, UINT);
BOOL   CloseHandle(HANDLE);
]]
-- END --

-- Constants --
    local GENERIC_WRITE        = 0x40000000
    local FILE_SHARE_READ      = 0x00000001
    local FILE_SHARE_WRITE     = 0x00000002
    local CREATE_ALWAYS        = 2
    local FILE_ATTRIBUTE_NORMAL= 0x00000080
    local STARTF_USESTDHANDLES = 0x00000100
    local CREATE_NO_WINDOW     = 0x08000000
    local STD_INPUT_HANDLE     = 0xFFFFFFF6  -- (DWORD)-10
    local WAIT_OBJECT_0        = 0
    local POLL_MS              = 40           -- how often the runloop tails the child

    local IS_WINDOWS = package.config:sub(1, 1) == "\\"

    local function tempDir()
        return (os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or ".")
            :gsub("[/\\]+$", "")
    end
-- END --

-- Windows command-line quoting (CommandLineToArgvW rules) --
    -- Wrap an argument in quotes if empty or containing whitespace/quote; double
    -- any backslashes that precede a quote, and escape embedded quotes. Enough for
    -- the flags/URLs/paths mac/ passes; keeps args intact through CreateProcessA.
    local function quoteArg(a)
        a = tostring(a)
        if a ~= "" and not a:find('[ \t"]') then return a end
        local out, bs = {}, 0
        for i = 1, #a do
            local c = a:sub(i, i)
            if c == "\\" then
                bs = bs + 1
            elseif c == '"' then
                out[#out + 1] = string.rep("\\", bs * 2 + 1) .. '"'
                bs = 0
            else
                if bs > 0 then out[#out + 1] = string.rep("\\", bs); bs = 0 end
                out[#out + 1] = c
            end
        end
        if bs > 0 then out[#out + 1] = string.rep("\\", bs * 2) end
        return '"' .. table.concat(out) .. '"'
    end

    -- Resolve the executable: use the given path verbatim if it opens (a real file
    -- on this OS); otherwise fall back to the basename so CreateProcess PATH-searches
    -- (mac's /usr/bin/curl -> curl -> curl.exe on PATH).
    local function resolveExe(path)
        local f = io.open(path, "rb")
        if f then f:close(); return path end
        return path:match("[^/\\]+$") or path
    end
-- END --

local task = {}

-- Task object --
    local Task = {}
    Task.__index = Task

    -- Read whatever a file holds now, from byte offset `from` (0-based). Returns
    -- the new chunk and the new offset. Missing file => empty chunk.
    local function readFrom(path, from)
        local f = io.open(path, "rb")
        if not f then return "", from end
        f:seek("set", from)
        local chunk = f:read("*a") or ""
        f:close()
        return chunk, from + #chunk
    end

    -- Finish: read final output, fire doneFn(exitCode, stdout, stderr), clean up.
    local function finish(self, exitCode)
        -- Tail any last streamed bytes before the done callback.
        if self._streamFn then
            local chunk; chunk, self._outPos = readFrom(self._outPath, self._outPos)
            if chunk ~= "" then pcall(self._streamFn, self, chunk, "") end
        end
        local outAll = (io.open(self._outPath, "rb"))
        local errAll = (io.open(self._errPath, "rb"))
        local stdout = outAll and (outAll:read("*a") or "") or ""
        local stderr = errAll and (errAll:read("*a") or "") or ""
        if outAll then outAll:close() end
        if errAll then errAll:close() end

        if self._hProc then K.CloseHandle(self._hProc); self._hProc = nil end
        if self._hThread then K.CloseHandle(self._hThread); self._hThread = nil end
        os.remove(self._outPath)
        os.remove(self._errPath)
        self._running = false

        if self._doneFn then
            local ok, err = pcall(self._doneFn, exitCode, stdout, stderr)
            if not ok then
                io.stderr:write("hs.task done callback error: " .. tostring(err) .. "\n")
            end
        end
    end

    function Task:start()
        if self._running then return self end
        if not IS_WINDOWS then
            io.stderr:write("[hs.task] only implemented on Windows; start() is a no-op here\n")
            return nil
        end

        local stamp = tostring(os.time()) .. "_" .. tostring(math.random(1, 1e9))
        self._outPath = tempDir() .. "/mudspoon_task_" .. stamp .. ".out"
        self._errPath = tempDir() .. "/mudspoon_task_" .. stamp .. ".err"
        self._outPos  = 0

        -- Inheritable temp-file handles for the child's stdout/stderr.
        local sa = ffi.new("SECURITY_ATTRIBUTES")
        sa.nLength = ffi.sizeof("SECURITY_ATTRIBUTES")
        sa.lpSecurityDescriptor = nil
        sa.bInheritHandle = 1

        local shareRW = bit.bor(FILE_SHARE_READ, FILE_SHARE_WRITE)
        local hOut = K.CreateFileA(self._outPath, GENERIC_WRITE, shareRW, sa,
            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nil)
        local hErr = K.CreateFileA(self._errPath, GENERIC_WRITE, shareRW, sa,
            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nil)
        local INVALID = ffi.cast("HANDLE", ffi.cast("intptr_t", -1))
        if hOut == INVALID or hErr == INVALID then
            if hOut ~= INVALID then K.CloseHandle(hOut) end
            if hErr ~= INVALID then K.CloseHandle(hErr) end
            return nil
        end

        -- Build the command line: quoted exe + quoted args.
        local parts = { quoteArg(resolveExe(self._path)) }
        for _, a in ipairs(self._args) do parts[#parts + 1] = quoteArg(a) end
        local cmdline = table.concat(parts, " ")
        -- CreateProcessA may modify lpCommandLine in place, so pass a writable copy.
        local cmdbuf = ffi.new("char[?]", #cmdline + 1)
        ffi.copy(cmdbuf, cmdline)

        local si = ffi.new("STARTUPINFOA")
        si.cb = ffi.sizeof("STARTUPINFOA")
        si.dwFlags = STARTF_USESTDHANDLES
        si.hStdInput  = K.GetStdHandle(STD_INPUT_HANDLE)
        si.hStdOutput = hOut
        si.hStdError  = hErr

        local pi = ffi.new("PROCESS_INFORMATION")
        -- lpApplicationName NULL => resolve program from the command line + PATH.
        local ok = K.CreateProcessA(nil, cmdbuf, nil, nil, true,
            CREATE_NO_WINDOW, nil, nil, si, pi)

        -- The child inherited its own copies of the handles; drop ours so the files
        -- close (and flush) when the child exits.
        K.CloseHandle(hOut)
        K.CloseHandle(hErr)

        if ok == 0 then
            os.remove(self._outPath)
            os.remove(self._errPath)
            return nil
        end

        self._hProc   = pi.hProcess
        self._hThread = pi.hThread
        self._running = true

        -- Poll for exit (and tail stdout for streaming tasks) off the one runloop.
        self._handle = host.schedule(POLL_MS, function()
            if not self._running then return end
            if self._streamFn then
                local chunk; chunk, self._outPos = readFrom(self._outPath, self._outPos)
                if chunk ~= "" then
                    -- hs contract: the streaming callback returns true to keep receiving
                    -- output, false to stop. pcall's 1st result is its own ok flag, so we
                    -- must read the 2nd (the callback's return). On an explicit false we
                    -- drop the streamFn -- no more stream callbacks -- while still polling
                    -- for exit so the done callback and cleanup still fire.
                    local ok, ret = pcall(self._streamFn, self, chunk, "")
                    if ok and ret == false then self._streamFn = nil end
                end
            end
            if self._hProc and K.WaitForSingleObject(self._hProc, 0) == WAIT_OBJECT_0 then
                local code = ffi.new("DWORD[1]")
                K.GetExitCodeProcess(self._hProc, code)
                if self._handle then self._handle:cancel(); self._handle = nil end
                finish(self, tonumber(code[0]))
            end
        end, POLL_MS)

        return self
    end

    -- Kill the child and tear down. Fires the done callback with the kill code so
    -- callers waiting on it aren't left hanging.
    function Task:terminate()
        if not self._running then return self end
        if self._hProc then pcall(function() K.TerminateProcess(self._hProc, 1) end) end
        if self._handle then self._handle:cancel(); self._handle = nil end
        finish(self, -1)
        return self
    end

    function Task:isRunning()
        return self._running == true
    end
-- END --

-- new --
    -- new(path, doneFn, streamFnOrArgs[, argsTable]). The 3rd arg is a streaming
    -- callback when it's a function, or the argument array when it's a table.
    function task.new(path, doneFn, third, fourth)
        local streamFn, args
        if type(third) == "function" then
            streamFn = third
            args     = fourth
        elseif type(third) == "table" then
            args     = third
        end
        return setmetatable({
            _path     = path,
            _doneFn   = doneFn,
            _streamFn = streamFn,
            _args     = args or {},
            _running  = false,
        }, Task)
    end
-- END --

return task
