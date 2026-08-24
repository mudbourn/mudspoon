-- probe: does the hook fire at all --
    local ffi = require("ffi")
    local bit = require("bit")

    local U = ffi.load("user32")
    local K = ffi.load("kernel32")

    ffi.cdef[[
typedef void*     HANDLE;
typedef void*     HHOOK;
typedef void*     HINSTANCE;
typedef void*     HMODULE;
typedef void*     HWND;
typedef unsigned int  UINT;
typedef unsigned long DWORD;
typedef int       BOOL;
typedef long      LONG;
typedef uintptr_t WPARAM;
typedef uintptr_t ULONG_PTR;
typedef intptr_t  LPARAM;
typedef intptr_t  LRESULT;

typedef struct { LONG x; LONG y; } POINT;
typedef struct { DWORD vkCode; DWORD scanCode; DWORD flags; DWORD time; ULONG_PTR dwExtraInfo; } KBDLLHOOKSTRUCT;
typedef struct { HWND hwnd; UINT message; WPARAM wParam; LPARAM lParam; DWORD time; POINT pt; } MSG;
typedef LRESULT (__stdcall *HOOKPROC)(int, WPARAM, LPARAM);

HMODULE GetModuleHandleA(const char*);
HHOOK   SetWindowsHookExA(int, HOOKPROC, HINSTANCE, DWORD);
BOOL    UnhookWindowsHookEx(HHOOK);
LRESULT CallNextHookEx(HHOOK, int, WPARAM, LPARAM);
short   GetAsyncKeyState(int);
BOOL    PeekMessageA(MSG*, HWND, UINT, UINT, UINT);
BOOL    TranslateMessage(const MSG*);
LRESULT DispatchMessageA(const MSG*);
DWORD   MsgWaitForMultipleObjects(DWORD, const HANDLE*, BOOL, DWORD, DWORD);
]]

    local WH_KEYBOARD_LL = 13
    local WM_KEYDOWN     = 0x0100
    local WM_SYSKEYDOWN  = 0x0104
    local PM_REMOVE      = 0x0001
    local QS_ALLINPUT    = 0x04FF
    local INFINITE       = 0xFFFFFFFF
    local VK_CONTROL     = 0x11
    local VK_MENU        = 0x12
    local VK_Q           = 0x51
    local HIGH_BIT       = 0x8000

    local running = { on = true }

    local function down(vk)
        return bit.band(U.GetAsyncKeyState(vk), HIGH_BIT) ~= 0
    end

    local cb = ffi.cast("HOOKPROC", function(nCode, wParam, lParam)
        if nCode >= 0 and (wParam == WM_KEYDOWN or wParam == WM_SYSKEYDOWN) then
            local kb   = ffi.cast("KBDLLHOOKSTRUCT*", lParam)
            local ctrl = down(VK_CONTROL)
            local alt  = down(VK_MENU)
            print(string.format("key vk=0x%X ctrl=%s alt=%s", tonumber(kb.vkCode), tostring(ctrl), tostring(alt)))
            io.flush()
            if ctrl and alt and kb.vkCode == VK_Q then running.on = false end
        end
        return U.CallNextHookEx(nil, nCode, wParam, lParam)
    end)

    local hInst = K.GetModuleHandleA(nil)
    local hook = U.SetWindowsHookExA(WH_KEYBOARD_LL, cb, hInst, 0)
    if hook == nil then error("SetWindowsHookExA failed") end

    print("probe running. press keys. Ctrl+Alt+Q to quit.")
    io.flush()

    local msg = ffi.new("MSG")
    while running.on do
        U.MsgWaitForMultipleObjects(0, nil, false, INFINITE, QS_ALLINPUT)
        while U.PeekMessageA(msg, nil, 0, 0, PM_REMOVE) ~= 0 do
            U.TranslateMessage(msg)
            U.DispatchMessageA(msg)
        end
    end

    U.UnhookWindowsHookEx(hook)
    print("probe stopped.")
-- END --
