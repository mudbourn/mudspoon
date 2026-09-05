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

typedef void* HWINEVENTHOOK;
typedef void (__stdcall *WINEVENTPROC)(HWINEVENTHOOK, DWORD, HWND, LONG, LONG, DWORD, DWORD);
HWINEVENTHOOK SetWinEventHook(DWORD, DWORD, HMODULE, WINEVENTPROC, DWORD, DWORD, DWORD);
BOOL    UnhookWinEvent(HWINEVENTHOOK);
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
    local WM_XBUTTONDOWN = 0x020B
    local WM_XBUTTONUP   = 0x020C
    local WM_MOUSEWHEEL  = 0x020A
    local WM_MOUSEHWHEEL = 0x020E

    local PM_REMOVE      = 0x0001
    local QS_ALLINPUT    = 0x04FF
    local INFINITE       = 0xFFFFFFFF

    -- WinEvent (SetWinEventHook) constants. These name the OS-level UI notifications
    -- host.onWinEvent surfaces; hs.application.watcher and hs.window.filter build on them.
    local EVENT_SYSTEM_FOREGROUND     = 0x0003  -- foreground window changed
    local EVENT_OBJECT_CREATE         = 0x8000
    local EVENT_OBJECT_DESTROY        = 0x8001
    local EVENT_OBJECT_SHOW           = 0x8002
    local EVENT_OBJECT_HIDE           = 0x8003
    local EVENT_OBJECT_LOCATIONCHANGE = 0x800B  -- moved/resized (chatty: fires per step)
    local WINEVENT_OUTOFCONTEXT       = 0x0000  -- deliver via our message pump (no DLL inject)
    local WINEVENT_SKIPOWNPROCESS     = 0x0002  -- never report our own windows
    local OBJID_WINDOW                = 0        -- the window itself, not a child object
    local CHILDID_SELF                = 0


    local VK_SHIFT       = 0x10
    local VK_CONTROL     = 0x11
    local VK_MENU        = 0x12  -- Alt
    local VK_LWIN        = 0x5B
    local VK_RWIN        = 0x5C
    local VK_CANCEL      = 0x03  -- Ctrl+Pause/Break
    local VK_PAUSE       = 0x13
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
    -- WinEvent codes surfaced to onWinEvent subscribers (numbers), so window.filter /
    -- application.watcher can classify events without re-hardcoding the constants.
    winEvents = {
        foreground     = EVENT_SYSTEM_FOREGROUND,
        objectCreate   = EVENT_OBJECT_CREATE,
        objectDestroy  = EVENT_OBJECT_DESTROY,
        objectShow     = EVENT_OBJECT_SHOW,
        objectHide     = EVENT_OBJECT_HIDE,
        locationChange = EVENT_OBJECT_LOCATIONCHANGE,
        OBJID_WINDOW   = OBJID_WINDOW,
        CHILDID_SELF   = CHILDID_SELF,
    },
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

    -- Live (uncancelled) scheduled-timer count. Diagnostic: every timer sits on this
    -- one pump, so a monotonically climbing count across an action = a timer leak, and
    -- the pump gets slower the longer this grows. Cheap O(n) walk; call sparingly.
    function host.timerCount()
        local c = 0
        for _ in pairs(timers) do c = c + 1 end
        return c
    end

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
                if not ok then io.stderr:write("hammerspoon timer error: " .. tostring(err) .. "\n") end
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

    -- Held-key set, keyed by vkCode, for autorepeat detection. The LL keyboard hook
    -- gives no repeat flag (unlike WM_KEYDOWN's lParam bit 30, unavailable here), so
    -- hardware autorepeat shows up as consecutive keyDowns with no intervening keyUp.
    -- A keyDown for a vk already marked held is a repeat -> keyboardEventAutorepeat.
    local keyHeld = {}

    -- Which button each down/up message owns, and the drag type to emit while it
    -- is held. Highest-priority held button (left > right > other) names the drag,
    -- mirroring hs, which reports one *Dragged type per move.
    local BTN_DOWN = { [WM_LBUTTONDOWN] = 0, [WM_RBUTTONDOWN] = 1, [WM_MBUTTONDOWN] = 2 }
    local BTN_UP   = { [WM_LBUTTONUP]   = 0, [WM_RBUTTONUP]   = 1, [WM_MBUTTONUP]   = 2 }
    local DRAG_TYPE = { [0] = "leftMouseDragged", [1] = "rightMouseDragged", [2] = "otherMouseDragged", [3] = "otherMouseDragged", [4] = "otherMouseDragged" }
    local btnHeld = { [0] = false, [1] = false, [2] = false, [3] = false, [4] = false }

    -- The held button (lowest number = highest priority) driving a drag, or nil.
    local function dragButton()
        if btnHeld[0] then return 0 end
        if btnHeld[1] then return 1 end
        if btnHeld[2] then return 2 end
        if btnHeld[3] then return 3 end
        if btnHeld[4] then return 4 end
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
                io.stderr:write("hammerspoon event handler error: " .. tostring(res) .. "\n")
            elseif res == true then
                swallow = true
            end
        end
        return swallow
    end

    -- Emergency stop. Ctrl+Alt+Pause (or Ctrl+Alt+Break) in the key hook calls this;
    -- so can a consumer. It snapshots the keys/buttons the hooks think are held,
    -- clears that state, and hands the snapshot to every registered handler so they
    -- can release the synthetic input and cancel running work. Handlers run under
    -- pcall so one bad handler cannot block the rest.
    local panicSubs = {}

    function host.onPanic(fn)
        panicSubs[#panicSubs + 1] = fn
        return function()
            for i = #panicSubs, 1, -1 do
                if panicSubs[i] == fn then table.remove(panicSubs, i) break end
            end
        end
    end

    function host.panic(reason)
        local heldKeys = {}
        for vk in pairs(keyHeld) do heldKeys[#heldKeys + 1] = vk end
        local heldBtns = {}
        for b = 0, 4 do if btnHeld[b] then heldBtns[#heldBtns + 1] = b end end
        for vk in pairs(keyHeld) do keyHeld[vk] = nil end
        for b = 0, 4 do btnHeld[b] = false end
        local snap = {
            keys    = heldKeys,
            buttons = heldBtns,
            reason  = reason,
        }
        for _, fn in ipairs(panicSubs) do pcall(fn, snap) end
    end

    -- The event surface reports macOS keycodes (hs parity); the hook reads Win32 VKs.
    -- keycodes.vkToMac bridges them. A leaf module, so the require never cycles; it
    -- falls back to identity if the map is not yet on package.path.
    local vkToMac
    do
        local ok, kc = pcall(require, "hs.keycodes")
        vkToMac = (ok and kc and kc.vkToMac) or function(vk) return vk end
    end

    local function installKeyHook()
        -- Create the ffi callback ONCE and reuse it across every install/uninstall
        -- cycle. UnhookWindowsHookEx does not guarantee no further calls: the OS can
        -- deliver one more LL callback that was already in flight, so the callback
        -- must outlive the hook. Freeing it (the old keyProc=nil on uninstall) let
        -- GC collect it and a late OS call hit freed memory -> "bad callback" panic,
        -- intermittently, whenever bind setup thrashed the hook while input flowed.
        if not keyProc then
        -- The hook body is a plain Lua function (not the FFI callback itself) so it
        -- can be jit.off'd and driven under pcall: an error must NEVER unwind out of
        -- the ffi.cast callback across the OS-hook boundary. Under the JIT that unwind
        -- lands in the middle of a compiled trace's mcode -> "PANIC: ... bad callback".
        local function keyBody(nCode, wParam, lParam)
            local swallow = false
            if nCode >= 0 then
                local t = KEY_TYPE[tonumber(wParam)]
                if t then
                    local kb    = ffi.cast("KBDLLHOOKSTRUCT*", lParam)
                    local extra = tonumber(kb.dwExtraInfo)
                    local vk    = tonumber(kb.vkCode)
                    -- Emergency stop: Ctrl+Alt+Pause (or Ctrl+Alt+Break) releases held
                    -- synthetic input and cancels running work, then passes through.
                    if t == "keyDown" and (vk == VK_PAUSE or vk == VK_CANCEL)
                        and down(VK_CONTROL) and down(VK_MENU) then
                        pcall(host.panic, "hotkey")
                    end
                    -- Autorepeat: a keyDown for a key already held (no keyUp since) is
                    -- a hardware repeat. Update held-state off the raw down/up type,
                    -- before t is possibly rewritten to flagsChanged below.
                    local autorepeat = false
                    if t == "keyDown" then
                        autorepeat = keyHeld[vk] == true
                        keyHeld[vk] = true
                    elseif t == "keyUp" then
                        keyHeld[vk] = nil
                    end
                    -- A modifier key transition is a flagsChanged, not keyDown/keyUp
                    -- (hs contract). currentFlags() reads real-time async state, so
                    -- by the time this fires the pressed/released bit is settled.
                    if MODIFIER_VK[vk] then t = "flagsChanged" end
                    local ev = host.newEvent{
                        type    = t,
                        keyCode = vkToMac(vk),
                        flags   = currentFlags(),
                        props   = {
                            scanCode   = tonumber(kb.scanCode),
                            injected   = bit.band(kb.flags, LLKHF_INJECTED) ~= 0,
                            autorepeat = autorepeat,
                            extra      = extra,
                        },
                    }
                    if dispatch(keySubs, ev) then swallow = true end
                end
            end
            return swallow
        end
        jit.off(keyBody, true)
        keyProc = ffi.cast("HOOKPROC", function(nCode, wParam, lParam)
            local ok, swallow = pcall(keyBody, nCode, wParam, lParam)
            if not ok then io.stderr:write("hammerspoon key hook error: " .. tostring(swallow) .. "\n") end
            if ok and swallow then return 1 end
            return U.CallNextHookEx(nil, nCode, wParam, lParam)
        end)
        end
        keyHook = U.SetWindowsHookExA(WH_KEYBOARD_LL, keyProc, host.moduleHandle, 0)
        if keyHook == nil then error("SetWindowsHookExA (keyboard) failed") end
    end

    local function installMouseHook()
        if not mouseProc then
        -- See keyBody above: jit.off'd body under pcall so no Lua error can unwind
        -- out of the ffi.cast callback across the OS-hook boundary ("bad callback").
        local function mouseBody(nCode, wParam, lParam)
            local swallow = false
            if nCode >= 0 then
                local wp = tonumber(wParam)
                local ms = ffi.cast("MSLLHOOKSTRUCT*", lParam)
                -- WM_MOUSEWHEEL packs the signed delta in the high word of mouseData;
                -- WM_XBUTTON* packs the thumb-button id (XBUTTON1=1, XBUTTON2=2) there.
                local hiword = bit.arshift(bit.band(tonumber(ms.mouseData), 0xFFFFFFFF), 16)
                -- Track button state before typing the event so a move that arrives
                -- in the same held-button window is seen as a drag.
                local evType, evButton
                if wp == WM_XBUTTONDOWN or wp == WM_XBUTTONUP then
                    evButton = 2 + bit.band(hiword, 0xFFFF)
                    evType   = (wp == WM_XBUTTONDOWN) and "otherMouseDown" or "otherMouseUp"
                    btnHeld[evButton] = (wp == WM_XBUTTONDOWN)
                else
                    local dn = BTN_DOWN[wp]; if dn then btnHeld[dn] = true  end
                    local up = BTN_UP[wp];   if up then btnHeld[up] = false end
                    local m = MOUSE_TYPE[wp]
                    if m then evType, evButton = m[1], m[2] end
                end
                if wp ~= WM_MOUSEMOVE and wp ~= WM_MOUSEWHEEL and wp ~= WM_MOUSEHWHEEL then
                    io.stderr:write(string.format(
                        "[mousediag] wp=0x%04X evType=%s evButton=%s hiword=%d\n",
                        wp, tostring(evType), tostring(evButton), hiword))
                    io.stderr:flush()
                end
                if evType then
                    local extra = tonumber(ms.dwExtraInfo)
                    local wheel = hiword
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
                    if dispatch(mouseSubs, ev) then swallow = true end
                end
            end
            return swallow
        end
        jit.off(mouseBody, true)
        mouseProc = ffi.cast("HOOKPROC", function(nCode, wParam, lParam)
            local ok, swallow = pcall(mouseBody, nCode, wParam, lParam)
            if not ok then io.stderr:write("hammerspoon mouse hook error: " .. tostring(swallow) .. "\n") end
            if ok and swallow then return 1 end
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

    -- WinEvent source: OS-level UI-object notifications (foreground change, window
    -- create/destroy/show/hide, move/resize). Unlike the LL hooks these are NOT
    -- swallowable -- SetWinEventHook is notify-only, so subscriber return values are
    -- ignored. fn receives (event, hwnd, idObject, idChild), all numbers/HWND cdata.
    --
    -- OUTOFCONTEXT delivery means the OS posts these to OUR thread and the callback
    -- runs while we pump messages (host.run) -- same thread as everything else, no
    -- extra runloop, and (like the LL hooks) entered from the jit.off'd pump so the
    -- JIT never enters the FFI callback ("bad callback" panic). SKIPOWNPROCESS keeps
    -- our own webview/alert windows from generating self-noise.
    local winSubs  = {}
    local winProc                   -- WINEVENTPROC; created ONCE, kept for the process
                                    -- lifetime (a late in-flight call after UnhookWinEvent
                                    -- must land on a live callback, not freed memory).
    local winHooks = {}             -- HWINEVENTHOOK handles while installed

    local function installWinHook()
        if not winProc then
            -- Body is a plain Lua function so it can be jit.off'd and pcall-driven: no
            -- error may unwind out of the ffi.cast callback across the OS boundary.
            local function winBody(_hook, event, hwnd, idObject, idChild)
                event    = tonumber(event)
                idObject = tonumber(idObject)
                idChild  = tonumber(idChild)
                for _, fn in ipairs(winSubs) do
                    local ok, err = pcall(fn, event, hwnd, idObject, idChild)
                    if not ok then
                        io.stderr:write("hammerspoon winevent handler error: " .. tostring(err) .. "\n")
                    end
                end
            end
            jit.off(winBody, true)
            winProc = ffi.cast("WINEVENTPROC", function(hook, event, hwnd, idObj, idChild, thread, time)
                local ok, err = pcall(winBody, hook, event, hwnd, idObj, idChild)
                if not ok then io.stderr:write("hammerspoon winevent hook error: " .. tostring(err) .. "\n") end
            end)
        end
        if #winHooks == 0 then
            -- Three narrow ranges rather than one broad [0x8000,0x800B] span: the middle
            -- object events (reorder/focus/selection/statechange) are high-volume and
            -- unused, so we skip them. FOREGROUND drives activation; CREATE..HIDE drive
            -- launch/terminate/show/hide; LOCATIONCHANGE drives move/resize.
            -- hmodWinEventProc MUST be NULL for WINEVENT_OUTOFCONTEXT (the callback is
            -- in our own process, not an injected DLL). idProcess/idThread 0 = all.
            local flags = bit.bor(WINEVENT_OUTOFCONTEXT, WINEVENT_SKIPOWNPROCESS)
            winHooks = {
                U.SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nil, winProc, 0, 0, flags),
                U.SetWinEventHook(EVENT_OBJECT_CREATE,     EVENT_OBJECT_HIDE,       nil, winProc, 0, 0, flags),
                U.SetWinEventHook(EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE, nil, winProc, 0, 0, flags),
            }
            local any = false
            for _, h in ipairs(winHooks) do if h ~= nil then any = true end end
            if not any then error("SetWinEventHook failed (all ranges)") end
        end
    end

    -- Remove the hooks but KEEP winProc alive (see installKeyHook rationale).
    local function uninstallWinHook()
        for i = 1, #winHooks do
            if winHooks[i] ~= nil then U.UnhookWinEvent(winHooks[i]) end
        end
        winHooks = {}
    end

    function host.onWinEvent(fn)
        return subscribe(winSubs, installWinHook, uninstallWinHook, fn)
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
        -- Watchdog heartbeat: an external monitor (launch.ps1) kills this host if the
        -- file stops being touched, so a hung runloop can never freeze system input for
        -- more than a few seconds. Writing after runTimers means a macro that hangs a
        -- timer callback stops the heartbeat, which is exactly the case we must catch.
        -- The idle wait is capped so the loop still ticks (and beats) on a quiet desktop.
        local hbFile = os.getenv("MUDSPOON_HEARTBEAT_FILE")
        local hbLast = 0
        while running do
            local to = nextTimeout()
            if hbFile and (to == nil or to > 1000) then to = 1000 end
            U.MsgWaitForMultipleObjects(0, nil, false, to or INFINITE, QS_ALLINPUT)
            while U.PeekMessageA(msgBuf, nil, 0, 0, PM_REMOVE) ~= 0 do
                U.TranslateMessage(msgBuf)
                U.DispatchMessageA(msgBuf)
            end
            runTimers()
            if hbFile then
                local now = host.now()
                if now - hbLast >= 1000 then
                    hbLast = now
                    pcall(function()
                        local f = io.open(hbFile, "w")
                        if f then
                            f:write(tostring(now))
                            f:close()
                        end
                    end)
                end
            end
        end
    end
    -- Keep the pump loop INTERPRETED. PeekMessageA/DispatchMessageA/MsgWaitForMultiple-
    -- Objects here synchronously invoke our FFI callbacks (wndProcs, and the LL keyboard/
    -- mouse hooks). LuaJIT cannot enter a callback from JIT-compiled mcode -- doing so
    -- raises "PANIC: unprotected error in call to Lua API (bad callback)". Compiling this
    -- hot loop is exactly what made the panic intermittent (it fired once the loop got
    -- hot, ~1s into boot). jit.off on the callbacks alone does NOT help; the offending
    -- trace is the CALLER that makes the C call. Non-recursive: callees still JIT freely.
    jit.off(host.run)

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
        uninstallWinHook()
    end
-- END --

return host
