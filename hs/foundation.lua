-- mudspoon foundation --
    -- The single shared substrate every hs.* module hangs off:
    --   * one Win32 message pump married to one Lua timer scheduler, on one thread
    --   * one low-level keyboard hook and one low-level mouse hook, fanned out
    --     to subscribers (host dispatch contract)
    --   * the shared event object shape (event contract), constructed here so
    --     the read side (hs.eventtap read) and the post side (hs.eventtap.event)
    --     cannot diverge
    --   * a monotonic clock and the timer-scheduler core hs.timer wraps
    --
    -- No other module installs a hook or runs a message loop. They register with
    -- host.onKey / host.onMouse / host.schedule and return a table; hs/init.lua
    -- wires the tables together.
    --
    -- This module owns every shared Win32 typedef. Other modules ffi.cdef only
    -- the *functions* they call (LuaJIT errors on a duplicate typedef, so base
    -- types must be declared exactly once, here).
-- END --

local ffi = require("ffi")
local bit = require("bit")

local U = ffi.load("user32")
local K = ffi.load("kernel32")
local G = ffi.load("gdi32")

-- Shared Win32 Types (owned here; do not re-typedef elsewhere) --
    ffi.cdef[[
typedef void*          HANDLE;
typedef void*          HWND;
typedef void*          HHOOK;
typedef void*          HINSTANCE;
typedef void*          HMODULE;
typedef void*          HMENU;
typedef void*          HBRUSH;
typedef void*          HICON;
typedef void*          HCURSOR;
typedef void*          HDC;
typedef void*          HGDIOBJ;
typedef void*          HRGN;
typedef const char*    LPCSTR;
typedef unsigned int   UINT;
typedef unsigned long  DWORD;
typedef int            BOOL;
typedef long           LONG;
typedef unsigned short WORD;
typedef unsigned char  BYTE;
typedef uintptr_t      WPARAM;
typedef uintptr_t      ULONG_PTR;
typedef intptr_t       LPARAM;
typedef intptr_t       LRESULT;
typedef long long      LONGLONG;
typedef unsigned long long ULONGLONG;

typedef struct { LONG x; LONG y; } POINT;
typedef struct { LONG left; LONG top; LONG right; LONG bottom; } RECT;

typedef struct { DWORD vkCode; DWORD scanCode; DWORD flags; DWORD time; ULONG_PTR dwExtraInfo; } KBDLLHOOKSTRUCT;
typedef struct { POINT pt; DWORD mouseData; DWORD flags; DWORD time; ULONG_PTR dwExtraInfo; } MSLLHOOKSTRUCT;
typedef struct { HWND hwnd; UINT message; WPARAM wParam; LPARAM lParam; DWORD time; POINT pt; } MSG;
typedef struct { HDC hdc; BOOL fErase; RECT rcPaint; BOOL fRestore; BOOL fIncUpdate; BYTE rgbReserved[32]; } PAINTSTRUCT;

typedef LRESULT (__stdcall *HOOKPROC)(int, WPARAM, LPARAM);
typedef LRESULT (__stdcall *WNDPROC)(HWND, UINT, WPARAM, LPARAM);

typedef struct {
  UINT cbSize; UINT style; WNDPROC lpfnWndProc; int cbClsExtra; int cbWndExtra;
  HINSTANCE hInstance; HICON hIcon; HCURSOR hCursor; HBRUSH hbrBackground;
  LPCSTR lpszMenuName; LPCSTR lpszClassName; HICON hIconSm;
} WNDCLASSEXA;
]]
-- END --

-- Foundation's own functions --
    ffi.cdef[[
HMODULE GetModuleHandleA(LPCSTR);
BOOL    QueryPerformanceCounter(LONGLONG*);
BOOL    QueryPerformanceFrequency(LONGLONG*);

HHOOK   SetWindowsHookExA(int, HOOKPROC, HINSTANCE, DWORD);
BOOL    UnhookWindowsHookEx(HHOOK);
LRESULT CallNextHookEx(HHOOK, int, WPARAM, LPARAM);
short   GetAsyncKeyState(int);
BOOL    PeekMessageA(MSG*, HWND, UINT, UINT, UINT);
BOOL    TranslateMessage(const MSG*);
LRESULT DispatchMessageA(const MSG*);
DWORD   MsgWaitForMultipleObjects(DWORD, const HANDLE*, BOOL, DWORD, DWORD);
]]
-- END --

-- Constants --
    local WH_KEYBOARD_LL = 13
    local WH_MOUSE_LL    = 14

    local WM_KEYDOWN     = 0x0100
    local WM_KEYUP       = 0x0101
    local WM_SYSKEYDOWN  = 0x0104
    local WM_SYSKEYUP    = 0x0105

    local WM_MOUSEMOVE   = 0x0200
    local WM_LBUTTONDOWN = 0x0201
    local WM_LBUTTONUP   = 0x0202
    local WM_RBUTTONDOWN = 0x0204
    local WM_RBUTTONUP   = 0x0205
    local WM_MBUTTONDOWN = 0x0207
    local WM_MBUTTONUP   = 0x0208
    local WM_MOUSEWHEEL  = 0x020A
    local WM_MOUSEHWHEEL = 0x020E

    local PM_REMOVE      = 0x0001
    local QS_ALLINPUT    = 0x04FF
    local INFINITE       = 0xFFFFFFFF

    local VK_SHIFT       = 0x10
    local VK_CONTROL     = 0x11
    local VK_MENU        = 0x12  -- Alt
    local VK_LWIN        = 0x5B
    local VK_RWIN        = 0x5C
    local HIGH_BIT       = 0x8000

    -- vkCodes that carry no character of their own, only a modifier state. A key
    -- event on any of these is emitted as "flagsChanged" (hs parity), never
    -- keyDown/keyUp. Covers the generic (0x10-0x12) and L/R-specific vkCodes the
    -- LL hook actually delivers (0xA0-0xA5), plus the Win keys.
    local MODIFIER_VK = {
        [0x10] = true, [0x11] = true, [0x12] = true,          -- shift / control / alt
        [0xA0] = true, [0xA1] = true,                         -- L/R shift
        [0xA2] = true, [0xA3] = true,                         -- L/R control
        [0xA4] = true, [0xA5] = true,                         -- L/R alt (menu)
        [0x5B] = true, [0x5C] = true,                         -- L/R win
    }

    local LLKHF_INJECTED = 0x10  -- low-level hook flags: event was synthesized
    local LLMHF_INJECTED = 0x01

    -- Signature stamped into dwExtraInfo by events this process posts, so the
    -- read side can tell its own injected events apart from real hardware.
    local INJECTED_MAGIC = 0x6D756473  -- 'muds'
-- END --

local host = {
    ffi              = ffi,
    bit              = bit,
    C                = { user32 = U, kernel32 = K, gdi32 = G },
    moduleHandle     = K.GetModuleHandleA(nil),
    INJECTED_MAGIC   = INJECTED_MAGIC,
}

-- Monotonic Clock --
    -- host.now() -> milliseconds as a double, from QueryPerformanceCounter.
    -- Monotonic and drift-free; the timebase hs.timer builds on.
    local qpcFreq do
        local f = ffi.new("LONGLONG[1]")
        K.QueryPerformanceFrequency(f)
        qpcFreq = tonumber(f[0])
    end

    local qpcBuf = ffi.new("LONGLONG[1]")

    function host.now()
        K.QueryPerformanceCounter(qpcBuf)
        return tonumber(qpcBuf[0]) / qpcFreq * 1000.0
    end
-- END --

-- Event Object (the event contract) --
    -- One shape shared by the read side (built from a hook payload) and the
    -- post side (built from a spec, then :post()). Methods live on eventMeta so
    -- hs.eventtap.event can attach :post without redefining the object.
    --
    -- spec fields:
    --   type      string   e.g. "keyDown", "leftMouseDown", "mouseMoved"
    --   keyCode   number    virtual-key code (see hs.keycodes for names)
    --   flags     table     set of active modifiers, truthy keys only:
    --                       ctrl, alt, shift, cmd (cmd aliases the Win key)
    --   props     table     extra read-only fields (x, y, scanCode, mouseData,
    --                       buttonNumber, injected, extra)
    local eventProto = {}
    local eventMeta  = { __index = eventProto }

    function eventProto:getType()        return self._type              end
    function eventProto:getKeyCode()     return self._keyCode           end
    function eventProto:getFlags()       return self._flags             end
    function eventProto:getProperty(k)   return self._props[k]          end

    -- Overridden by hs.eventtap.event once it is required (owns SendInput).
    function eventProto:post()
        error("hs.eventtap.event is not loaded; require it before posting events", 2)
    end

    function host.newEvent(spec)
        return setmetatable({
            _type    = spec.type,
            _keyCode = spec.keyCode,
            _flags   = spec.flags or {},
            _props   = spec.props or {},
        }, eventMeta)
    end

    host.eventProto = eventProto
    host.eventMeta  = eventMeta
-- END --

-- Modifier Snapshot --
    local function down(vk)
        return bit.band(U.GetAsyncKeyState(vk), HIGH_BIT) ~= 0
    end

    -- Set-table of currently held modifiers. Only truthy keys are present.
    local function currentFlags()
        local f = {}
        if down(VK_CONTROL) then f.ctrl  = true end
        if down(VK_MENU)    then f.alt   = true end
        if down(VK_SHIFT)   then f.shift = true end
        if down(VK_LWIN) or down(VK_RWIN) then f.cmd = true end
        return f
    end
-- END --

-- Scheduler Core (what hs.timer wraps) --
    -- host.schedule(delayMs, fn, intervalMs?) -> handle
    --   one-shot when intervalMs is nil; repeating (period intervalMs, first
    --   fire after delayMs) otherwise. handle:cancel() stops it.
    local timers = {}  -- live set, keyed by handle

    local function schedule(delayMs, fn, intervalMs)
        local h = {
            due      = host.now() + delayMs,
            fn       = fn,
            interval = intervalMs,
            live     = true,
        }
        function h:cancel()
            self.live = false
            timers[self] = nil
        end
        timers[h] = h
        return h
    end
    host.schedule = schedule

    -- Milliseconds until the soonest due timer, or nil if none. Clamped to >= 0.
    local function nextTimeout()
        local n, best = host.now(), nil
        for h in pairs(timers) do
            local d = h.due - n
            if d < 0 then d = 0 end
            if not best or d < best then best = d end
        end
        return best
    end

    -- Fire everything due. Repeating timers reschedule off their own due time so
    -- cadence does not drift. Snapshot first: a fn may cancel or add timers.
    local function runTimers()
        local n, ready = host.now(), {}
        for h in pairs(timers) do
            if h.due <= n then ready[#ready + 1] = h end
        end
        for _, h in ipairs(ready) do
            if h.live then
                if h.interval then
                    h.due = h.due + h.interval
                    if h.due <= host.now() then h.due = host.now() + h.interval end
                else
                    h.live = false
                    timers[h] = nil
                end
                local ok, err = pcall(h.fn)
                if not ok then io.stderr:write("mudspoon timer error: " .. tostring(err) .. "\n") end
            end
        end
    end
-- END --

-- Host Dispatch (the dispatch contract) --
    -- host.onKey(fn) / host.onMouse(fn) -> unsubscribe handle (call it to remove).
    -- fn receives an event object. Returning true swallows the event: the OS
    -- never sees it and later subscribers do not run.
    --
    -- The underlying low-level hook is installed on the first subscriber of its
    -- kind and removed when the last one leaves, so an idle host holds no hook.
    local keySubs   = {}
    local mouseSubs = {}
    local keyHook, mouseHook            -- HHOOK handles (nil when not installed)
    local keyProc,  mouseProc           -- ffi callbacks; created ONCE, kept for the
                                        -- process lifetime (see installKeyHook). GC
                                        -- of a live LL callback = "bad callback" panic.

    -- keyboard message -> event type
    local KEY_TYPE = {
        [WM_KEYDOWN]    = "keyDown",  [WM_SYSKEYDOWN] = "keyDown",
        [WM_KEYUP]      = "keyUp",    [WM_SYSKEYUP]   = "keyUp",
    }

    -- Which button each down/up message owns, and the drag type to emit while it
    -- is held. Highest-priority held button (left > right > other) names the drag,
    -- mirroring hs, which reports one *Dragged type per move.
    local BTN_DOWN = { [WM_LBUTTONDOWN] = 0, [WM_RBUTTONDOWN] = 1, [WM_MBUTTONDOWN] = 2 }
    local BTN_UP   = { [WM_LBUTTONUP]   = 0, [WM_RBUTTONUP]   = 1, [WM_MBUTTONUP]   = 2 }
    local DRAG_TYPE = { [0] = "leftMouseDragged", [1] = "rightMouseDragged", [2] = "otherMouseDragged" }
    local btnHeld = { [0] = false, [1] = false, [2] = false }

    -- The held button (lowest number = highest priority) driving a drag, or nil.
    local function dragButton()
        if btnHeld[0] then return 0 end
        if btnHeld[1] then return 1 end
        if btnHeld[2] then return 2 end
        return nil
    end

    -- mouse message -> {type, buttonNumber}
    local MOUSE_TYPE = {
        [WM_MOUSEMOVE]   = { "mouseMoved" },
        [WM_LBUTTONDOWN] = { "leftMouseDown",  0 }, [WM_LBUTTONUP] = { "leftMouseUp",  0 },
        [WM_RBUTTONDOWN] = { "rightMouseDown", 1 }, [WM_RBUTTONUP] = { "rightMouseUp", 1 },
        [WM_MBUTTONDOWN] = { "otherMouseDown", 2 }, [WM_MBUTTONUP] = { "otherMouseUp", 2 },
        [WM_MOUSEWHEEL]  = { "scrollWheel" },
        [WM_MOUSEHWHEEL] = { "scrollWheel" },
    }

    -- Fan out to subscribers; true from any of them means swallow.
    local function dispatch(subs, ev)
        local swallow = false
        for _, fn in ipairs(subs) do
            local ok, res = pcall(fn, ev)
            if not ok then
                io.stderr:write("mudspoon event handler error: " .. tostring(res) .. "\n")
            elseif res == true then
                swallow = true
            end
        end
        return swallow
    end

    local function installKeyHook()
        -- Create the ffi callback ONCE and reuse it across every install/uninstall
        -- cycle. UnhookWindowsHookEx does not guarantee no further calls: the OS can
        -- deliver one more LL callback that was already in flight, so the callback
        -- must outlive the hook. Freeing it (the old keyProc=nil on uninstall) let
        -- GC collect it and a late OS call hit freed memory -> "bad callback" panic,
        -- intermittently, whenever bind setup thrashed the hook while input flowed.
        if not keyProc then
        keyProc = ffi.cast("HOOKPROC", function(nCode, wParam, lParam)
            if nCode >= 0 then
                local t = KEY_TYPE[tonumber(wParam)]
                if t then
                    local kb    = ffi.cast("KBDLLHOOKSTRUCT*", lParam)
                    local extra = tonumber(kb.dwExtraInfo)
                    local vk    = tonumber(kb.vkCode)
                    -- A modifier key transition is a flagsChanged, not keyDown/keyUp
                    -- (hs contract). currentFlags() reads real-time async state, so
                    -- by the time this fires the pressed/released bit is settled.
                    if MODIFIER_VK[vk] then t = "flagsChanged" end
                    local ev = host.newEvent{
                        type    = t,
                        keyCode = vk,
                        flags   = currentFlags(),
                        props   = {
                            scanCode = tonumber(kb.scanCode),
                            injected = bit.band(kb.flags, LLKHF_INJECTED) ~= 0,
                            extra    = extra,
                        },
                    }
                    if dispatch(keySubs, ev) then return 1 end
                end
            end
            return U.CallNextHookEx(nil, nCode, wParam, lParam)
        end)
        end
        keyHook = U.SetWindowsHookExA(WH_KEYBOARD_LL, keyProc, host.moduleHandle, 0)
        if keyHook == nil then error("SetWindowsHookExA (keyboard) failed") end
    end

    local function installMouseHook()
        if not mouseProc then
        mouseProc = ffi.cast("HOOKPROC", function(nCode, wParam, lParam)
            if nCode >= 0 then
                local wp = tonumber(wParam)
                -- Track button state before typing the event so a move that arrives
                -- in the same held-button window is seen as a drag.
                local dn = BTN_DOWN[wp]; if dn then btnHeld[dn] = true  end
                local up = BTN_UP[wp];   if up then btnHeld[up] = false end
                local m = MOUSE_TYPE[wp]
                if m then
                    local ms    = ffi.cast("MSLLHOOKSTRUCT*", lParam)
                    local extra = tonumber(ms.dwExtraInfo)
                    -- WM_MOUSEWHEEL packs the signed delta in the high word of mouseData.
                    local wheel = bit.arshift(bit.band(tonumber(ms.mouseData), 0xFFFFFFFF), 16)
                    local evType, evButton = m[1], m[2]
                    -- A move with a button held is a drag, named by that button.
                    if wp == WM_MOUSEMOVE then
                        local db = dragButton()
                        if db then evType, evButton = DRAG_TYPE[db], db end
                    end
                    local ev = host.newEvent{
                        type    = evType,
                        keyCode = nil,
                        flags   = currentFlags(),
                        props   = {
                            x            = tonumber(ms.pt.x),
                            y            = tonumber(ms.pt.y),
                            buttonNumber = evButton,
                            mouseData    = wheel,
                            injected     = bit.band(ms.flags, LLMHF_INJECTED) ~= 0,
                            extra        = extra,
                        },
                    }
                    if dispatch(mouseSubs, ev) then return 1 end
                end
            end
            return U.CallNextHookEx(nil, nCode, wParam, lParam)
        end)
        end
        mouseHook = U.SetWindowsHookExA(WH_MOUSE_LL, mouseProc, host.moduleHandle, 0)
        if mouseHook == nil then error("SetWindowsHookExA (mouse) failed") end
    end

    local function subscribe(subs, install, uninstall, fn)
        subs[#subs + 1] = fn
        if #subs == 1 then install() end
        return function()
            for i = #subs, 1, -1 do
                if subs[i] == fn then table.remove(subs, i) break end
            end
            if #subs == 0 then uninstall() end
        end
    end

    -- Remove the OS hook but KEEP keyProc/mouseProc alive (see installKeyHook): a
    -- late in-flight LL call after UnhookWindowsHookEx must land on a live callback,
    -- not freed memory. The kept callback just falls through to CallNextHookEx.
    local function uninstallKeyHook()
        if keyHook then U.UnhookWindowsHookEx(keyHook); keyHook = nil end
    end
    local function uninstallMouseHook()
        if mouseHook then U.UnhookWindowsHookEx(mouseHook); mouseHook = nil end
    end

    function host.onKey(fn)
        return subscribe(keySubs, installKeyHook, uninstallKeyHook, fn)
    end
    function host.onMouse(fn)
        return subscribe(mouseSubs, installMouseHook, uninstallMouseHook, fn)
    end
-- END --

-- Runloop --
    -- The one message pump + scheduler tick. host.run() blocks until host.stop().
    -- Everything (timers, hook dispatch, alert animation) advances from here.
    local running = false
    local msgBuf  = ffi.new("MSG")

    function host.run()
        if running then return end
        running = true
        while running do
            local to = nextTimeout()
            U.MsgWaitForMultipleObjects(0, nil, false, to or INFINITE, QS_ALLINPUT)
            while U.PeekMessageA(msgBuf, nil, 0, 0, PM_REMOVE) ~= 0 do
                U.TranslateMessage(msgBuf)
                U.DispatchMessageA(msgBuf)
            end
            runTimers()
        end
    end

    -- Safe to call from a timer or an event handler (same thread). The current
    -- loop iteration finishes, then run() returns.
    function host.stop()
        running = false
    end

    -- Release every hook so the process can exit without leaving the OS holding
    -- a stale WH_*_LL. Call once on shutdown.
    function host.shutdown()
        host.stop()
        uninstallKeyHook()
        uninstallMouseHook()
    end
-- END --

return host
