-- hs.ipc: command endpoint for the hs CLI (bin/hs_cli.lua) --

local ffi = require("ffi")

local host = require("hs.foundation")

-- Loads the declarations of RegisterClassExA, CreateWindowExA and DefWindowProcA
require("hs.menubar")

-- Loads the declarations of COPYDATASTRUCT and SendMessageTimeoutA
require("hs.distributednotifications")

-- Own FFI surface --
    ffi.cdef[[
BOOL IsWindow(HWND);
]]
-- END --

local U     = host.C.user32
local hInst = host.moduleHandle

-- Constants --
    local WM_COPYDATA      = 0x004A
    local SMTO_ABORTIFHUNG = 0x0002
    local REPLY_TIMEOUT_MS = 2000
    local MAGIC_REQUEST    = 0x4D534951
    local MAGIC_OK         = 0x4D53494F
    local MAGIC_ERROR      = 0x4D534945
    local CLASS            = "HammerspoonIpcPort"
    local HWND_MESSAGE     = -3
    local MAX_PAYLOAD      = 16 * 1024 * 1024
-- END --

local ipc = {}

local classBuf = ffi.new("char[?]", #CLASS + 1)

ffi.copy(classBuf, CLASS)

-- Loads source as an expression first and as a statement block second
local function compile(source)
    local chunk = load("return " .. source, "=hs")

    if chunk then return chunk end

    return load(source, "=hs")
end

-- Runs Lua source in the global env and returns the printed text, the returned values and an error flag
local function evaluate(source)
    local printed = {}
    local realPrint = _G.print

    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring((select(i, ...)))
        end
        printed[#printed + 1] = table.concat(parts, "\t") .. "\n"
    end

    local isError = false
    local returned = ""

    local ran, runErr = pcall(function()
        local chunk, loadErr = compile(source)

        if not chunk then
            isError = true
            returned = tostring(loadErr) .. "\n"
            return
        end

        local packed = table.pack(pcall(chunk))

        if not packed[1] then
            isError = true
            returned = tostring(packed[2]) .. "\n"
            return
        end

        local parts = {}

        for i = 2, packed.n do
            parts[#parts + 1] = tostring(packed[i])
        end

        if #parts > 0 then returned = table.concat(parts, "\t") .. "\n" end
    end)

    _G.print = realPrint

    if not ran then
        isError = true
        returned = tostring(runErr) .. "\n"
    end

    return table.concat(printed) .. returned, isError
end

-- Sends the reply payload to the CLI's window
local function reply(replyHwnd, text, isError)
    local buf = ffi.new("char[?]", #text + 1)

    ffi.copy(buf, text, #text)

    local cds = ffi.new("COPYDATASTRUCT[1]")

    cds[0].dwData = isError and MAGIC_ERROR or MAGIC_OK
    cds[0].cbData = #text
    cds[0].lpData = buf

    local resultBuf = ffi.new("uintptr_t[1]")

    U.SendMessageTimeoutA(
        ffi.cast("HWND", replyHwnd),
        WM_COPYDATA,
        ffi.cast("WPARAM", 0),
        ffi.cast("LPARAM", cds),
        SMTO_ABORTIFHUNG,
        REPLY_TIMEOUT_MS,
        resultBuf
    )
end

-- Handles one request message, failing quietly on anything malformed
local function handleCopyData(lp)
    local cds = ffi.cast("COPYDATASTRUCT*", lp)

    if cds.dwData ~= MAGIC_REQUEST or cds.lpData == nil or cds.cbData == 0 or cds.cbData > MAX_PAYLOAD then return end

    local payload = ffi.string(cds.lpData, cds.cbData)
    local replyText, source = payload:match("^(%d+)\n(.*)$")
    local replyHwnd = tonumber(replyText)

    if not replyHwnd or replyHwnd == 0 then return end

    if U.IsWindow(ffi.cast("HWND", replyHwnd)) == 0 then return end

    local text, isError = evaluate(source)

    pcall(reply, replyHwnd, text, isError)
end

-- Process-wide class anchor shared by every module instance
local anchor = host._ipcClass

if not anchor then
    anchor = {}

    host._ipcClass = anchor

    -- Window procedure for the endpoint window
    local function wndProcFn(hwnd, msg, wp, lp)
        if msg == WM_COPYDATA then
            local ok, err = pcall(function()
                anchor.handle(lp)
            end)

            if not ok then io.stderr:write("hs.ipc request error: " .. tostring(err) .. "\n") end

            return 1
        end

        return U.DefWindowProcA(hwnd, msg, wp, lp)
    end

    anchor.proc = ffi.cast("WNDPROC", wndProcFn)
end

anchor.handle = handleCopyData

-- Registers the window class once for the process
local function ensureClass()
    if anchor.registered then return end

    local wc = ffi.new("WNDCLASSEXA")

    wc.cbSize        = ffi.sizeof("WNDCLASSEXA")
    wc.lpfnWndProc   = anchor.proc
    wc.hInstance     = hInst
    wc.lpszClassName = classBuf

    if U.RegisterClassExA(wc) == 0 then error("hs.ipc: RegisterClassExA failed") end

    anchor.registered = true
end

-- Creates one endpoint object with its own message-only window
local function newPort()
    ensureClass()

    local win = U.CreateWindowExA(0, classBuf, "", 0, 0, 0, 0, 0, ffi.cast("HWND", HWND_MESSAGE), nil, hInst, nil)

    if win == nil then error("hs.ipc: CreateWindowExA failed") end

    local port = { _win = win }

    function port:delete()
        if self._win ~= nil then
            U.DestroyWindow(self._win)
            self._win = nil
        end
    end

    return port
end

-- Starts the default endpoint once
ipc.__default = newPort()

-- Pretends the command line tool is installed
function ipc.cliInstall()
    return true
end

-- Reports the command line tool as installed
function ipc.cliStatus()
    return true
end

return ipc
