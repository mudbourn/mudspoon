-- hs command line client for the mudspoon host (pure LuaJIT FFI) --

local ffi = require("ffi")

ffi.cdef[[
typedef void *HANDLE;
typedef struct { uintptr_t dwData; uint32_t cbData; void *lpData; } COPYDATASTRUCT;
typedef struct { void *hwnd; uint32_t message; uintptr_t wParam; intptr_t lParam; uint32_t time; long x; long y; } CLIMSG;
typedef intptr_t (__stdcall *CLIWNDPROC)(void*, uint32_t, uintptr_t, intptr_t);
typedef struct {
    uint32_t cbSize; uint32_t style; CLIWNDPROC lpfnWndProc; int cbClsExtra; int cbWndExtra;
    void *hInstance; void *hIcon; void *hCursor; void *hbrBackground;
    const char *lpszMenuName; const char *lpszClassName; void *hIconSm;
} CLIWNDCLASSEX;
uint16_t RegisterClassExA(const CLIWNDCLASSEX*);
void *CreateWindowExA(uint32_t, const char*, const char*, uint32_t, int, int, int, int, void*, void*, void*, void*);
intptr_t DefWindowProcA(void*, uint32_t, uintptr_t, intptr_t);
void *FindWindowExA(void*, void*, const char*, const char*);
intptr_t SendMessageTimeoutA(void*, uint32_t, uintptr_t, intptr_t, uint32_t, uint32_t, uintptr_t*);
int PeekMessageA(CLIMSG*, void*, uint32_t, uint32_t, uint32_t);
intptr_t DispatchMessageA(const CLIMSG*);
uint32_t GetTickCount(void);
void Sleep(uint32_t);
void *GetModuleHandleA(const char*);
uint32_t GetWindowThreadProcessId(void*, uint32_t*);
void *OpenProcess(uint32_t, int, uint32_t);
int CloseHandle(void*);
int GetProcessTimes(void*, uint64_t*, uint64_t*, uint64_t*, uint64_t*);
]]

local U = ffi.load("user32")

local K = ffi.load("kernel32")

-- Constants --
    local WM_COPYDATA      = 0x004A
    local SMTO_ABORTIFHUNG = 0x0002
    local MAGIC_REQUEST    = 0x4D534951
    local MAGIC_OK         = 0x4D53494F
    local MAGIC_ERROR      = 0x4D534945
    local HOST_CLASS       = "HammerspoonIpcPort"
    local CLIENT_CLASS     = "HammerspoonIpcClient"
    local HWND_MESSAGE     = ffi.cast("void*", -3)
    local TIMEOUT_MS       = 30000
    local PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
-- END --

local replyText
local replyIsError = false

-- Receives the host's reply
local function clientProc(hwnd, msg, wp, lp)
    if msg == WM_COPYDATA then
        local cds = ffi.cast("COPYDATASTRUCT*", lp)

        if cds.dwData == MAGIC_OK or cds.dwData == MAGIC_ERROR then
            replyText = ffi.string(cds.lpData, cds.cbData)
            replyIsError = cds.dwData == MAGIC_ERROR
        end

        return 1
    end

    return U.DefWindowProcA(hwnd, msg, wp, lp)
end

local clientProcCb = ffi.cast("CLIWNDPROC", clientProc)

local hInst = K.GetModuleHandleA(nil)

local wc = ffi.new("CLIWNDCLASSEX")

wc.cbSize        = ffi.sizeof("CLIWNDCLASSEX")
wc.lpfnWndProc   = clientProcCb
wc.hInstance     = hInst
wc.lpszClassName = CLIENT_CLASS

U.RegisterClassExA(wc)

local clientWin = U.CreateWindowExA(0, CLIENT_CLASS, "", 0, 0, 0, 0, 0, HWND_MESSAGE, nil, hInst, nil)

if clientWin == nil then
    io.stderr:write("hs: cannot create reply window\n")
    os.exit(2)
end

-- Returns the creation time of the process owning a window, or 0
local function creationTimeOf(win)
    local pidBuf = ffi.new("uint32_t[1]")

    U.GetWindowThreadProcessId(win, pidBuf)

    local h = K.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pidBuf[0])

    if h == nil then return 0 end

    local times = ffi.new("uint64_t[4]")

    local ok = K.GetProcessTimes(h, times, times + 1, times + 2, times + 3)

    K.CloseHandle(h)

    return ok ~= 0 and tonumber(times[0]) or 0
end

-- Picks the host window of MUDSPOON_IPC_PID when set, else of the newest host process
local function findHostWindow()
    local wantPid = tonumber(os.getenv("MUDSPOON_IPC_PID") or "")
    local best = nil
    local bestTime = -1
    local win = nil

    repeat
        win = U.FindWindowExA(HWND_MESSAGE, win, HOST_CLASS, nil)

        if win ~= nil then
            local pidBuf = ffi.new("uint32_t[1]")

            U.GetWindowThreadProcessId(win, pidBuf)

            if wantPid and pidBuf[0] == wantPid then return win end

            local created = creationTimeOf(win)

            if created > bestTime then
                best = win
                bestTime = created
            end
        end
    until win == nil

    if wantPid then return nil end

    return best
end

-- Sends one command and returns its output text and error flag
local function send(source)
    local hostWin = findHostWindow()

    if hostWin == nil then
        io.stderr:write("hs: no mudspoon host is listening (start it with launch.ps1 -Dev)\n")
        os.exit(3)
    end

    local payload = tostring(tonumber(ffi.cast("uintptr_t", clientWin))) .. "\n" .. source

    local buf = ffi.new("char[?]", #payload + 1)

    ffi.copy(buf, payload, #payload)

    local cds = ffi.new("COPYDATASTRUCT[1]")

    cds[0].dwData = MAGIC_REQUEST
    cds[0].cbData = #payload
    cds[0].lpData = buf

    replyText = nil

    local resultBuf = ffi.new("uintptr_t[1]")

    local ok = U.SendMessageTimeoutA(
        hostWin,
        WM_COPYDATA,
        tonumber(ffi.cast("uintptr_t", clientWin)),
        ffi.cast("intptr_t", cds),
        SMTO_ABORTIFHUNG,
        TIMEOUT_MS,
        resultBuf
    )

    if ok == 0 then
        io.stderr:write("hs: the host did not answer within " .. (TIMEOUT_MS / 1000) .. " seconds\n")
        os.exit(4)
    end

    local msg = ffi.new("CLIMSG")

    local started = K.GetTickCount()

    while replyText == nil and K.GetTickCount() - started < TIMEOUT_MS do
        while U.PeekMessageA(msg, nil, 0, 0, 1) ~= 0 do
            U.DispatchMessageA(msg)
        end

        if replyText == nil then K.Sleep(5) end
    end

    if replyText == nil then
        io.stderr:write("hs: no reply from the host\n")
        os.exit(4)
    end

    return replyText, replyIsError
end

local commands = {}

local i = 1

while i <= #arg do
    local a = arg[i]

    if a == "-c" then
        commands[#commands + 1] = arg[i + 1]
        i = i + 2
    else
        io.stderr:write("hs: unknown argument " .. a .. "\nusage: hs [-c <lua>]...  (reads stdin when no -c is given)\n")
        os.exit(2)
    end
end

if #commands == 0 then
    commands[1] = io.read("*a") or ""
end

local exitCode = 0

for _, source in ipairs(commands) do
    local text, isError = send(source)

    if isError then
        io.stderr:write(text)
        if text:sub(-1) ~= "\n" then io.stderr:write("\n") end
        exitCode = 1
    else
        io.stdout:write(text)
    end
end

os.exit(exitCode)
