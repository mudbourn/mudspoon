-- mudspoon ground-breaking spike --
    -- Global keyboard hook, a Win32 message pump married to a Lua scheduler,
    -- and a native alert window, all from one LuaJIT process.
    -- Ctrl+Alt+K pops a fading alert and swallows the K. Ctrl+Alt+Q quits.
    -- Run on the Windows PC at the physical console, not over RDP.
-- END --

-- FFI Setup --
    local ffi = require("ffi")
    local bit = require("bit")

    local U = ffi.load("user32")
    local K = ffi.load("kernel32")
    local G = ffi.load("gdi32")
-- END --

-- Win32 Types --
    ffi.cdef[[
typedef void*         HANDLE;
typedef void*         HWND;
typedef void*         HHOOK;
typedef void*         HINSTANCE;
typedef void*         HMODULE;
typedef void*         HMENU;
typedef void*         HBRUSH;
typedef void*         HICON;
typedef void*         HCURSOR;
typedef void*         HDC;
typedef void*         HGDIOBJ;
typedef void*         HRGN;
typedef const char*   LPCSTR;
typedef unsigned int  UINT;
typedef unsigned long DWORD;
typedef int           BOOL;
typedef long          LONG;
typedef unsigned short WORD;
typedef unsigned char BYTE;
typedef uintptr_t     WPARAM;
typedef uintptr_t     ULONG_PTR;
typedef intptr_t      LPARAM;
typedef intptr_t      LRESULT;
typedef unsigned long long ULONGLONG;

typedef struct { LONG x; LONG y; } POINT;
typedef struct { LONG left; LONG top; LONG right; LONG bottom; } RECT;

typedef struct { DWORD vkCode; DWORD scanCode; DWORD flags; DWORD time; ULONG_PTR dwExtraInfo; } KBDLLHOOKSTRUCT;
typedef struct { HWND hwnd; UINT message; WPARAM wParam; LPARAM lParam; DWORD time; POINT pt; } MSG;
typedef struct { HDC hdc; BOOL fErase; RECT rcPaint; BOOL fRestore; BOOL fIncUpdate; BYTE rgbReserved[32]; } PAINTSTRUCT;

typedef LRESULT (__stdcall *HOOKPROC)(int, WPARAM, LPARAM);
typedef LRESULT (__stdcall *WNDPROC)(HWND, UINT, WPARAM, LPARAM);

typedef struct {
  UINT cbSize; UINT style; WNDPROC lpfnWndProc; int cbClsExtra; int cbWndExtra;
  HINSTANCE hInstance; HICON hIcon; HCURSOR hCursor; HBRUSH hbrBackground;
  LPCSTR lpszMenuName; LPCSTR lpszClassName; HICON hIconSm;
} WNDCLASSEXA;

HMODULE   GetModuleHandleA(LPCSTR);
ULONGLONG GetTickCount64(void);

HHOOK   SetWindowsHookExA(int, HOOKPROC, HINSTANCE, DWORD);
BOOL    UnhookWindowsHookEx(HHOOK);
LRESULT CallNextHookEx(HHOOK, int, WPARAM, LPARAM);
short   GetAsyncKeyState(int);
BOOL    PeekMessageA(MSG*, HWND, UINT, UINT, UINT);
BOOL    TranslateMessage(const MSG*);
LRESULT DispatchMessageA(const MSG*);
DWORD   MsgWaitForMultipleObjects(DWORD, const HANDLE*, BOOL, DWORD, DWORD);

WORD    RegisterClassExA(const WNDCLASSEXA*);
HWND    CreateWindowExA(DWORD, LPCSTR, LPCSTR, DWORD, int, int, int, int, HWND, HMENU, HINSTANCE, void*);
BOOL    ShowWindow(HWND, int);
BOOL    DestroyWindow(HWND);
LRESULT DefWindowProcA(HWND, UINT, WPARAM, LPARAM);
BOOL    SetLayeredWindowAttributes(HWND, DWORD, BYTE, DWORD);
int     GetSystemMetrics(int);
int     SetWindowRgn(HWND, HRGN, BOOL);
HDC     BeginPaint(HWND, PAINTSTRUCT*);
BOOL    EndPaint(HWND, const PAINTSTRUCT*);
BOOL    GetClientRect(HWND, RECT*);
int     FillRect(HDC, const RECT*, HBRUSH);

HBRUSH  CreateSolidBrush(DWORD);
HRGN    CreateRoundRectRgn(int, int, int, int, int, int);
BOOL    DeleteObject(HGDIOBJ);
int     SetBkMode(HDC, int);
DWORD   SetTextColor(HDC, DWORD);
BOOL    TextOutA(HDC, int, int, LPCSTR, int);
]]
-- END --

-- Constants --
    local WH_KEYBOARD_LL    = 13
    local WM_KEYDOWN        = 0x0100
    local WM_SYSKEYDOWN     = 0x0104
    local WM_PAINT          = 0x000F
    local WM_DESTROY        = 0x0002
    local PM_REMOVE         = 0x0001
    local QS_ALLINPUT       = 0x04FF
    local INFINITE          = 0xFFFFFFFF

    local WS_POPUP          = 0x80000000
    local EX_LAYERED        = 0x00080000
    local EX_TOPMOST        = 0x00000008
    local EX_TOOLWINDOW     = 0x00000080
    local EX_NOACTIVATE     = 0x08000000
    local SW_SHOWNOACTIVATE = 4
    local LWA_ALPHA         = 0x02
    local SM_CXSCREEN       = 0
    local SM_CYSCREEN       = 1
    local TRANSPARENT       = 1

    local VK_CONTROL        = 0x11
    local VK_MENU           = 0x12
    local VK_K              = 0x4B
    local VK_Q              = 0x51
    local HIGH_BIT          = 0x8000

    local EX_STYLE = bit.bor(EX_LAYERED, EX_TOPMOST, EX_TOOLWINDOW, EX_NOACTIVATE)
-- END --

-- State --
    local state = {
        running      = true,
        pendingAlert = false,
    }

    local hInst = K.GetModuleHandleA(nil)
-- END --

-- Scheduler --
    local timers = {}

    local function now()
        return tonumber(K.GetTickCount64())
    end

    local function after(ms, fn)
        timers[#timers + 1] = {
            due = now() + ms,
            fn  = fn,
        }
    end

    local function nextTimeout()
        local n, best = now(), nil

        for _, t in ipairs(timers) do
            local d = t.due - n
            if d < 0 then d = 0 end
            if not best or d < best then best = d end
        end

        return best
    end

    local function tick()
        local n, i = now(), 1

        while i <= #timers do
            if timers[i].due <= n then
                local fn = timers[i].fn
                table.remove(timers, i)
                fn()
            else
                i = i + 1
            end
        end
    end
-- END --

-- Alert Window --
    local CLASS = "MudspoonAlert"
    local classBuf = ffi.new("char[?]", #CLASS + 1)
    ffi.copy(classBuf, CLASS)

    local activeText  = ""
    local activeAlert = nil

    -- Window procedure --
        local wndProc = ffi.cast("WNDPROC", function(hwnd, msg, wp, lp)
            if msg == WM_PAINT then
                local ps  = ffi.new("PAINTSTRUCT")
                local hdc = U.BeginPaint(hwnd, ps)
                local rc  = ffi.new("RECT")
                U.GetClientRect(hwnd, rc)

                local brush = G.CreateSolidBrush(0x001C1F24)
                U.FillRect(hdc, rc, brush)
                G.DeleteObject(brush)

                G.SetBkMode(hdc, TRANSPARENT)
                G.SetTextColor(hdc, 0x00E8E8E8)
                G.TextOutA(hdc, 22, 36, activeText, #activeText)

                U.EndPaint(hwnd, ps)
                return 0
            elseif msg == WM_DESTROY then
                return 0
            end

            return U.DefWindowProcA(hwnd, msg, wp, lp)
        end)
    -- END --

    -- Register class --
        local wc = ffi.new("WNDCLASSEXA")
        wc.cbSize        = ffi.sizeof("WNDCLASSEXA")
        wc.lpfnWndProc   = wndProc
        wc.hInstance     = hInst
        wc.lpszClassName = classBuf

        if U.RegisterClassExA(wc) == 0 then error("RegisterClassExA failed") end
    -- END --

    -- Fade step --
        local function fadeStep()
            if not activeAlert then return end

            activeAlert.alpha = activeAlert.alpha - 20

            if activeAlert.alpha <= 0 then
                U.DestroyWindow(activeAlert.hwnd)
                activeAlert = nil
            else
                U.SetLayeredWindowAttributes(activeAlert.hwnd, 0, activeAlert.alpha, LWA_ALPHA)
                after(30, fadeStep)
            end
        end
    -- END --

    -- Show alert --
        local function showAlert(text)
            if activeAlert then return end

            activeText = text
            local w, h = 360, 96
            local x = U.GetSystemMetrics(SM_CXSCREEN) - w - 24
            local y = U.GetSystemMetrics(SM_CYSCREEN) - h - 80

            local hwnd = U.CreateWindowExA(EX_STYLE, classBuf, "", WS_POPUP, x, y, w, h, nil, nil, hInst, nil)
            if hwnd == nil then
                print("CreateWindowExA failed")
                return
            end

            U.SetWindowRgn(hwnd, G.CreateRoundRectRgn(0, 0, w + 1, h + 1, 20, 20), true)
            U.SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA)
            U.ShowWindow(hwnd, SW_SHOWNOACTIVATE)

            activeAlert = {
                hwnd  = hwnd,
                alpha = 255,
            }

            after(1400, fadeStep)
        end
    -- END --
-- END --

-- Keyboard Hook --
    local function down(vk)
        return bit.band(U.GetAsyncKeyState(vk), HIGH_BIT) ~= 0
    end

    -- Callback stays tiny: set a flag, return. See memory for why.
    local hookProc = ffi.cast("HOOKPROC", function(nCode, wParam, lParam)
        if nCode >= 0 and (wParam == WM_KEYDOWN or wParam == WM_SYSKEYDOWN) then
            local kb = ffi.cast("KBDLLHOOKSTRUCT*", lParam)

            if down(VK_CONTROL) and down(VK_MENU) then
                if kb.vkCode == VK_K then
                    state.pendingAlert = true
                    return 1
                elseif kb.vkCode == VK_Q then
                    state.running = false
                    return 1
                end
            end
        end

        return U.CallNextHookEx(nil, nCode, wParam, lParam)
    end)

    local hook = U.SetWindowsHookExA(WH_KEYBOARD_LL, hookProc, hInst, 0)
    if hook == nil then error("SetWindowsHookExA failed") end
-- END --

-- Event Loop --
    print("mudspoon spike running.")
    print("  Ctrl+Alt+K  -> native alert (K is swallowed)")
    print("  Ctrl+Alt+Q  -> quit")

    local msg = ffi.new("MSG")

    while state.running do
        local to = nextTimeout()
        U.MsgWaitForMultipleObjects(0, nil, false, to or INFINITE, QS_ALLINPUT)

        while U.PeekMessageA(msg, nil, 0, 0, PM_REMOVE) ~= 0 do
            U.TranslateMessage(msg)
            U.DispatchMessageA(msg)
        end

        if state.pendingAlert then
            state.pendingAlert = false
            showAlert("Ctrl+Alt+K  hook + loop + alert proven")
        end

        tick()
    end

    U.UnhookWindowsHookEx(hook)
    print("mudspoon spike stopped cleanly.")
-- END --
