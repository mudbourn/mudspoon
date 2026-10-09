local host = require("hs.foundation")
local shims = require("hs.shims")
local ffi  = host.ffi
local K    = host.C.kernel32

-- Process and pipe FFI --
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

typedef struct {
  int64_t   PerProcessUserTimeLimit;
  int64_t   PerJobUserTimeLimit;
  DWORD     LimitFlags;
  size_t    MinimumWorkingSetSize;
  size_t    MaximumWorkingSetSize;
  DWORD     ActiveProcessLimit;
  uintptr_t Affinity;
  DWORD     PriorityClass;
  DWORD     SchedulingClass;
} mudtask_JOBBASIC;

typedef struct {
  uint64_t ReadOperationCount;
  uint64_t WriteOperationCount;
  uint64_t OtherOperationCount;
  uint64_t ReadTransferCount;
  uint64_t WriteTransferCount;
  uint64_t OtherTransferCount;
} mudtask_IOCOUNTERS;

typedef struct {
  mudtask_JOBBASIC   BasicLimitInformation;
  mudtask_IOCOUNTERS IoInfo;
  size_t             ProcessMemoryLimit;
  size_t             JobMemoryLimit;
  size_t             PeakProcessMemoryUsed;
  size_t             PeakJobMemoryUsed;
} mudtask_JOBEXT;

BOOL   CreateProcessA(const char*, char*, void*, void*, BOOL, DWORD,
                  void*, const char*, STARTUPINFOA*, PROCESS_INFORMATION*);
DWORD  WaitForSingleObject(HANDLE, DWORD);
BOOL   GetExitCodeProcess(HANDLE, DWORD*);
BOOL   TerminateProcess(HANDLE, UINT);
BOOL   CloseHandle(HANDLE);
BOOL   CreatePipe(HANDLE*, HANDLE*, SECURITY_ATTRIBUTES*, DWORD);
BOOL   SetHandleInformation(HANDLE, DWORD, DWORD);
BOOL   WriteFile(HANDLE, const void*, DWORD, DWORD*, void*);
BOOL   SetNamedPipeHandleState(HANDLE, DWORD*, DWORD*, DWORD*);
BOOL   PeekNamedPipe(HANDLE, void*, DWORD, DWORD*, DWORD*, DWORD*);
BOOL   ReadFile(HANDLE, void*, DWORD, DWORD*, void*);
HANDLE CreateJobObjectW(void*, const unsigned short*);
BOOL   SetInformationJobObject(HANDLE, int, void*, DWORD);
BOOL   AssignProcessToJobObject(HANDLE, HANDLE);
DWORD  ResumeThread(HANDLE);
    ]]
-- END --

-- Constants --
    local STARTF_USESTDHANDLES = 0x00000100
    local CREATE_SUSPENDED     = 0x00000004
    local CREATE_NO_WINDOW     = 0x08000000
    local HANDLE_FLAG_INHERIT  = 0x00000001
    local JOB_KILL_ON_CLOSE    = 0x00002000
    local JOB_EXTENDED_INFO    = 9
    local PIPE_BYTES           = 1048576
    local PIPE_NOWAIT          = 0x00000001
    local nowaitMode           = ffi.new("DWORD[1]", PIPE_NOWAIT)
    local READ_CHUNK           = 65536
    local TICK_DRAIN_BYTES     = 4194304
    local WAIT_OBJECT_0        = 0
    local STREAM_POLL_MS       = 8
    local IDLE_POLL_MS         = 40
    local IS_WINDOWS           = package.config:sub(1, 1) == "\\"
-- END --

-- Job object that kills every child when the host exits --
    local job
    local jobTried = false

    local function childJob()
        if jobTried then return job end

        jobTried = true

        local h = K.CreateJobObjectW(nil, nil)

        if h == nil then return nil end

        local info = ffi.new("mudtask_JOBEXT")

        info.BasicLimitInformation.LimitFlags = JOB_KILL_ON_CLOSE

        if K.SetInformationJobObject(h, JOB_EXTENDED_INFO, info, ffi.sizeof(info)) == 0 then
            K.CloseHandle(h)

            return nil
        end

        job = h

        return job
    end
-- END --

-- Windows command-line quoting (CommandLineToArgvW rules) --
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
                if bs > 0 then
                    out[#out + 1] = string.rep("\\", bs)
                    bs = 0
                end

                out[#out + 1] = c
            end
        end

        if bs > 0 then out[#out + 1] = string.rep("\\", bs * 2) end

        return '"' .. table.concat(out) .. '"'
    end

    -- Uses the path verbatim when it opens, else its basename so CreateProcess searches PATH
    local function resolveExe(path)
        local f = io.open(path, "rb")

        if f then
            f:close()

            return path
        end

        return path:match("[^/\\]+$") or path
    end
-- END --

-- Anonymous pipes and draining --
    local readBuf = ffi.new("char[?]", READ_CHUNK)
    local availN  = ffi.new("DWORD[1]")
    local gotN    = ffi.new("DWORD[1]")

    -- Returns the parent end and the inheritable child end, or nil on failure
    local function makePipe(parentReads)
        local sa = ffi.new("SECURITY_ATTRIBUTES")

        sa.nLength = ffi.sizeof("SECURITY_ATTRIBUTES")
        sa.lpSecurityDescriptor = nil
        sa.bInheritHandle = 1

        local rd = ffi.new("HANDLE[1]")
        local wr = ffi.new("HANDLE[1]")

        if K.CreatePipe(rd, wr, ffi.cast("void*", sa), PIPE_BYTES) == 0 then return nil end

        local parent, child = wr[0], rd[0]

        if parentReads then parent, child = rd[0], wr[0] end

        K.SetHandleInformation(parent, HANDLE_FLAG_INHERIT, 0)

        return parent, child
    end

    -- Reads what is buffered right now without blocking, up to limit bytes
    local function drain(h, limit)
        if not h then return "" end

        local parts, total = {}, 0

        while total < limit do
            if K.PeekNamedPipe(h, nil, 0, nil, availN, nil) == 0 or availN[0] == 0 then break end

            local want = math.min(tonumber(availN[0]), READ_CHUNK)

            if K.ReadFile(h, readBuf, want, gotN, nil) == 0 or gotN[0] == 0 then break end

            parts[#parts + 1] = ffi.string(readBuf, gotN[0])
            total = total + tonumber(gotN[0])
        end

        return table.concat(parts)
    end

    local function closeHandle(h)
        if h then K.CloseHandle(h) end
    end
-- END --

local task = {}

-- Task object --
    local Task = {}
    Task.__index = Task

    local function fireDone(self, code, stdout, stderr)
        if not self._doneFn then return end

        local ok, err = pcall(self._doneFn, code, stdout, stderr)

        if not ok then
            io.stderr:write("hs.task done callback error: " .. tostring(err) .. "\n")
        end
    end

    -- Moves buffered child output into the accumulators and feeds the stream callback
    local function pump(self, limit)
        local out = drain(self._rdOut, limit)
        local err = drain(self._rdErr, limit)

        if out ~= "" then self._out[#self._out + 1] = out end

        if err ~= "" then self._err[#self._err + 1] = err end

        if self._streamFn and (out ~= "" or err ~= "") then
            local ok, ret = pcall(self._streamFn, self, out, err)

            if ok and ret == false then self._streamFn = nil end
        end
    end

    -- Writes what the stdin pipe accepts now, closing it once the backlog is empty and a close is pending
    local function flushInput(self)
        local stdin = self._stdin

        if not stdin then return end

        local pending = self._pending

        while pending and #pending > 0 do
            local wrote = ffi.new("DWORD[1]")

            if K.WriteFile(stdin, pending, #pending, wrote, nil) == 0 or wrote[0] == 0 then break end

            pending = pending:sub(tonumber(wrote[0]) + 1)
        end

        self._pending = pending

        if self._inputClosing and (not pending or #pending == 0) then
            K.CloseHandle(stdin)

            self._stdin = nil
            self._pending = nil
        end
    end

    -- Drains the last output, closes every handle and fires the done callback
    local function finish(self, exitCode)
        pump(self, math.huge)

        if self._stdin then
            K.CloseHandle(self._stdin)

            self._stdin = nil
        end

        self._pending = nil
        self._inputClosing = nil

        closeHandle(self._rdOut)
        closeHandle(self._rdErr)
        closeHandle(self._hProc)
        closeHandle(self._hThread)

        self._rdOut = nil
        self._rdErr = nil
        self._hProc = nil
        self._hThread = nil
        self._running = false

        local stdout = table.concat(self._out)
        local stderr = table.concat(self._err)

        self._out = {}
        self._err = {}

        fireDone(self, exitCode, stdout, stderr)
    end

    function Task:start()
        if self._running then return self end

        if not IS_WINDOWS then
            io.stderr:write("[hs.task] only implemented on Windows; start() is a no-op here\n")

            return nil
        end

        local exePath = self._path
        local exeArgs = self._args
        local base = exePath:match("[^/\\]+$")

        if base == "open" and not io.open(exePath, "rb") then
            local rc = shims.open(exeArgs)

            self._running = true
            self._handle = host.schedule(IDLE_POLL_MS, function()
                if self._handle then
                    self._handle:cancel()

                    self._handle = nil
                end

                self._running = false

                fireDone(self, rc, "", "")
            end, IDLE_POLL_MS)

            return self
        end

        if base == "zip" and not io.open(exePath, "rb") then
            local tarPath, tarArgs = shims.zipTaskArgs(exeArgs)

            if tarPath then
                exePath = tarPath
                exeArgs = tarArgs
            end
        end

        if base == "osascript" and not io.open(exePath, "rb") then
            local psPath, psArgs = shims.adminTaskArgs(exeArgs)

            if psPath then
                exePath = psPath
                exeArgs = psArgs
            end
        end

        local rdOut, wrOut = makePipe(true)
        local rdErr, wrErr = makePipe(true)
        local wrIn, rdIn = makePipe(false)

        if not (rdOut and rdErr and wrIn) then
            closeHandle(rdOut)

            closeHandle(wrOut)

            closeHandle(rdErr)

            closeHandle(wrErr)

            closeHandle(wrIn)

            closeHandle(rdIn)

            return nil
        end

        K.SetNamedPipeHandleState(wrIn, nowaitMode, nil, nil)

        local parts = { quoteArg(resolveExe(exePath)) }

        for _, a in ipairs(exeArgs) do parts[#parts + 1] = quoteArg(a) end

        local cmdline = table.concat(parts, " ")
        local cmdbuf = ffi.new("char[?]", #cmdline + 1)

        ffi.copy(cmdbuf, cmdline)

        local si = ffi.new("STARTUPINFOA")

        si.cb = ffi.sizeof("STARTUPINFOA")
        si.dwFlags = STARTF_USESTDHANDLES
        si.hStdInput = rdIn
        si.hStdOutput = wrOut
        si.hStdError = wrErr

        local pi = ffi.new("PROCESS_INFORMATION")

        local ok = K.CreateProcessA(nil, cmdbuf, nil, nil, true,
            (CREATE_NO_WINDOW | CREATE_SUSPENDED), nil, nil, si, pi)

        closeHandle(wrOut)

        closeHandle(wrErr)

        closeHandle(rdIn)

        if ok == 0 then
            closeHandle(rdOut)

            closeHandle(rdErr)

            closeHandle(wrIn)

            return nil
        end

        local hJob = childJob()

        if hJob then K.AssignProcessToJobObject(hJob, pi.hProcess) end

        K.ResumeThread(pi.hThread)

        self._rdOut   = rdOut
        self._rdErr   = rdErr
        self._stdin   = wrIn
        self._hProc   = pi.hProcess
        self._hThread = pi.hThread
        self._out     = {}
        self._err     = {}
        self._pending = nil
        self._inputClosing = nil
        self._running = true

        local pollMs = self._streamFn and STREAM_POLL_MS or IDLE_POLL_MS

        self._handle = host.schedule(pollMs, function()
            if not self._running then return end

            local exited = self._hProc and K.WaitForSingleObject(self._hProc, 0) == WAIT_OBJECT_0

            pump(self, TICK_DRAIN_BYTES)

            flushInput(self)

            if exited and self._running then
                local code = ffi.new("DWORD[1]")

                K.GetExitCodeProcess(self._hProc, code)

                if self._handle then
                    self._handle:cancel()

                    self._handle = nil
                end

                finish(self, tonumber(code[0]))
            end
        end, pollMs)

        return self
    end

    -- Kills the child and fires the done callback with code -1
    function Task:terminate()
        if not self._running then return self end

        if self._hProc then pcall(function() K.TerminateProcess(self._hProc, 1) end) end

        if self._handle then
            self._handle:cancel()

            self._handle = nil
        end

        finish(self, -1)

        return self
    end

    function Task:isRunning()
        return self._running == true
    end

    -- Task:setInput --
        function Task:setInput(data)
            if not self._stdin or self._inputClosing then return self end

            self._pending = (self._pending or "") .. tostring(data)

            flushInput(self)

            return self
        end
    -- END Task:setInput --

    -- Task:closeInput --
        function Task:closeInput()
            if not self._stdin then return true end

            self._inputClosing = true

            flushInput(self)

            return true
        end
    -- END Task:closeInput --
-- END --

-- new(path, doneFn, streamFnOrArgs[, argsTable]) --
    function task.new(path, doneFn, third, fourth)
        local streamFn, args

        if type(third) == "function" then
            streamFn = third
            args     = fourth
        elseif type(third) == "table" then
            args = third
        end

        return setmetatable({
            _path = path,
            _doneFn = doneFn,
            _streamFn = streamFn,
            _args = args or {},
            _running = false
        }, Task)
    end
-- END --

return task
