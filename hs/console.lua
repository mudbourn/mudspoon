-- hs.console: native Win32 console window with the log and a Lua input line --

local ffi = require("ffi")

local host = require("hs.foundation")

-- Loads the declarations of RegisterClassExA, CreateWindowExA and DefWindowProcA
require("hs.menubar")

local U = host.C.user32
local G = host.C.gdi32
local hInst = host.moduleHandle

-- Own FFI surface --
    for _, decl in ipairs({
        "BOOL ShowWindow(HWND, int);",
        "BOOL DestroyWindow(HWND);",
        "BOOL IsWindow(HWND);",
        "BOOL IsWindowVisible(HWND);",
        "BOOL SetForegroundWindow(HWND);",
        "HWND SetFocus(HWND);",
        "BOOL MoveWindow(HWND, int, int, int, int, BOOL);",
        "BOOL GetClientRect(HWND, RECT*);",
        "BOOL SetWindowTextA(HWND, LPCSTR);",
        "int  GetWindowTextA(HWND, char*, int);",
        "int  GetWindowTextLengthA(HWND);",
        "LRESULT SendMessageA(HWND, UINT, WPARAM, LPARAM);",
        "LRESULT CallWindowProcA(void*, HWND, UINT, WPARAM, LPARAM);",
        "intptr_t SetWindowLongPtrA(HWND, int, intptr_t);",
        "HCURSOR LoadCursorA(HINSTANCE, LPCSTR);",
        "void* CreateFontA(int, int, int, int, int, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, LPCSTR);"
    }) do
        pcall(ffi.cdef, decl)
    end
-- END --

-- Constants --
    local CLASS = "MudspoonConsole"

    local WS_OVERLAPPEDWINDOW = 0x00CF0000
    local WS_CHILD = 0x40000000
    local WS_VISIBLE = 0x10000000
    local WS_BORDER = 0x00800000
    local WS_VSCROLL = 0x00200000

    local ES_MULTILINE = 0x0004
    local ES_AUTOVSCROLL = 0x0040
    local ES_AUTOHSCROLL = 0x0080
    local ES_READONLY = 0x0800

    local WM_SIZE = 0x0005
    local WM_SETFOCUS = 0x0007
    local WM_CLOSE = 0x0010
    local WM_SETFONT = 0x0030
    local WM_KEYDOWN = 0x0100
    local WM_CHAR = 0x0102

    local EM_SETSEL = 0x00B1
    local EM_SCROLLCARET = 0x00B7
    local EM_REPLACESEL = 0x00C2
    local EM_SETLIMITTEXT = 0x00C5

    local GWLP_WNDPROC = -4
    local SW_HIDE = 0
    local SW_SHOW = 5
    local SW_RESTORE = 9
    local VK_UP = 0x26
    local VK_DOWN = 0x28
    local COLOR_WINDOW = 5
    local INPUT_HEIGHT = 26
    local MAX_CHARS = 400000
-- END --

local console = {}

local state = {
    win = nil,
    out = nil,
    input = nil,
    font = nil,
    origInputProc = nil,
    history = {},
    cursor = 0
}

local classReady = false

local classBuf = ffi.new("char[?]", #CLASS + 1)

ffi.copy(classBuf, CLASS)

local function toCrLf(text)
    return (text:gsub("\r?\n", "\r\n"))
end

-- Appends text to the output pane and keeps it scrolled to the end
local function appendText(text)
    if not state.out then return end

    if U.GetWindowTextLengthA(state.out) > MAX_CHARS then U.SetWindowTextA(state.out, "") end

    local len = U.GetWindowTextLengthA(state.out)

    local buf = ffi.new("char[?]", #text * 2 + 1)

    ffi.copy(buf, toCrLf(text))

    U.SendMessageA(state.out, EM_SETSEL, len, len)
    U.SendMessageA(state.out, EM_REPLACESEL, 0, ffi.cast("LPARAM", buf))
    U.SendMessageA(state.out, EM_SCROLLCARET, 0, 0)
end

-- Loads source as an expression first and as a statement block second
local function compile(source)
    local chunk = load("return " .. source, "=hs")

    if chunk then return chunk end

    return load(source, "=hs")
end

-- Runs one input line in the global env and prints the result or the error
local function evaluate(source)
    print("> " .. source)

    local chunk, loadErr = compile(source)

    if not chunk then
        print(tostring(loadErr))

        return
    end

    local packed = table.pack(pcall(chunk))

    if not packed[1] then
        print(tostring(packed[2]))

        return
    end

    local parts = {}

    for i = 2, packed.n do parts[#parts + 1] = tostring(packed[i]) end

    if #parts > 0 then print(table.concat(parts, "\t")) end
end

-- Reads the input line, clears it and evaluates it
local function submit()
    local len = U.GetWindowTextLengthA(state.input)
    local buf = ffi.new("char[?]", len + 1)

    U.GetWindowTextA(state.input, buf, len + 1)
    U.SetWindowTextA(state.input, "")

    local source = ffi.string(buf, len)

    if source:match("^%s*$") then return end

    state.history[#state.history + 1] = source
    state.cursor = #state.history + 1

    evaluate(source)
end

-- Steps through earlier input lines
local function recall(step)
    local target = state.cursor + step

    if target < 1 or target > #state.history + 1 then return end

    state.cursor = target

    U.SetWindowTextA(state.input, state.history[target] or "")
end

local function inputProcFn(hwnd, msg, wp, lp)
    local handled = false

    pcall(function()
        if msg == WM_CHAR and tonumber(wp) == 13 then
            submit()
            handled = true
        elseif msg == WM_KEYDOWN and tonumber(wp) == VK_UP then
            recall(-1)
            handled = true
        elseif msg == WM_KEYDOWN and tonumber(wp) == VK_DOWN then
            recall(1)
            handled = true
        end
    end)

    if handled then return 0 end

    return U.CallWindowProcA(state.origInputProc, hwnd, msg, wp, lp)
end

local inputProc = ffi.cast("WNDPROC", inputProcFn)

-- Sizes the output pane and the input line to the client area
local function layout()
    if not state.win then return end

    local rc = ffi.new("RECT")

    U.GetClientRect(state.win, rc)

    local w = rc.right - rc.left
    local h = rc.bottom - rc.top

    U.MoveWindow(state.out, 0, 0, w, h - INPUT_HEIGHT, 1)
    U.MoveWindow(state.input, 0, h - INPUT_HEIGHT, w, INPUT_HEIGHT, 1)
end

local function wndProcFn(hwnd, msg, wp, lp)
    if msg == WM_CLOSE then
        U.ShowWindow(hwnd, SW_HIDE)

        return 0
    end

    if msg == WM_SIZE then
        if state.out and state.input then pcall(layout) end

        return 0
    end

    if msg == WM_SETFOCUS and state.input then
        U.SetFocus(state.input)

        return 0
    end

    return U.DefWindowProcA(hwnd, msg, wp, lp)
end

local wndProc = ffi.cast("WNDPROC", wndProcFn)

-- Creates a child EDIT control
local function newEdit(parent, style)
    local edit = U.CreateWindowExA(0, "EDIT", "", (WS_CHILD | WS_VISIBLE | WS_BORDER | style),
        0, 0, 100, 100, parent, nil, hInst, nil)

    if edit == nil then error("hs.console: CreateWindowExA failed for EDIT") end

    U.SendMessageA(edit, WM_SETFONT, ffi.cast("WPARAM", state.font), 1)

    return edit
end

-- Builds the window once and fills the output with the buffered log
local function ensureWindow()
    if state.win and U.IsWindow(state.win) ~= 0 then return end

    if not classReady then
        local wc = ffi.new("WNDCLASSEXA")

        wc.cbSize = ffi.sizeof("WNDCLASSEXA")
        wc.lpfnWndProc = wndProc
        wc.hInstance = hInst
        wc.hCursor = U.LoadCursorA(nil, ffi.cast("LPCSTR", 32512))
        wc.hbrBackground = ffi.cast("HBRUSH", COLOR_WINDOW + 1)
        wc.lpszClassName = classBuf

        U.RegisterClassExA(wc)

        classReady = true
    end

    state.font = state.font or G.CreateFontA(-15, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 49, "Consolas")

    local win = U.CreateWindowExA(0, classBuf, "Hammerspoon Console", WS_OVERLAPPEDWINDOW,
        120, 120, 760, 480, nil, nil, hInst, nil)

    if win == nil then error("hs.console: CreateWindowExA failed") end

    state.win = win
    state.out = newEdit(win, (ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL | WS_VSCROLL))
    state.input = newEdit(win, ES_AUTOHSCROLL)

    U.SendMessageA(state.out, EM_SETLIMITTEXT, MAX_CHARS * 2, 0)

    state.origInputProc = ffi.cast("void*", U.SetWindowLongPtrA(state.input, GWLP_WNDPROC, ffi.cast("intptr_t", inputProc)))

    layout()

    local log = _G.__mudspoon_log

    if log then
        appendText(table.concat(log.tail))

        log.sink = appendText
    end
end

-- Shows the console window and focuses it unless bringToFront is false
function console.open(bringToFront)
    ensureWindow()

    U.ShowWindow(state.win, SW_RESTORE)
    U.ShowWindow(state.win, SW_SHOW)

    if bringToFront ~= false then U.SetForegroundWindow(state.win) end

    U.SetFocus(state.input)

    return console
end

-- Hides the console window
function console.close()
    if state.win and U.IsWindow(state.win) ~= 0 then U.ShowWindow(state.win, SW_HIDE) end

    return console
end

-- Reports whether the console window is visible
function console.isOpen()
    return state.win ~= nil and U.IsWindowVisible(state.win) ~= 0
end

-- Empties the output pane and the buffered log
function console.clearConsole()
    local log = _G.__mudspoon_log

    if log then
        for i = #log.tail, 1, -1 do log.tail[i] = nil end
    end

    if state.out then U.SetWindowTextA(state.out, "") end
end

-- Prints text with its styling dropped
function console.printStyledtext(...)
    local parts = {}

    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end

    print(table.concat(parts, " "))
end

-- Returns the output pane text
function console.getText()
    if not state.out then return "" end

    local len = U.GetWindowTextLengthA(state.out)
    local buf = ffi.new("char[?]", len + 1)

    U.GetWindowTextA(state.out, buf, len + 1)

    return ffi.string(buf, len)
end

-- Evaluates a line as if it was typed into the input
function console.eval(source)
    evaluate(source)
end

return console
