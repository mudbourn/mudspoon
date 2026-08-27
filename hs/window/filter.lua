-- hs.window.filter  (window-event subscription via Win32 SetWinEventHook) --
    -- A Hammerspoon-shaped hs.window.filter backed by SetWinEventHook. Real HS uses this
    -- to watch the set of windows matching a filter and emit windowCreated/Moved/... to
    -- subscribers. mudscript uses exactly one slice of it -- the MACRO RECORDER
    -- (ms_core.lua ~5827): create an unfiltered filter, snapshot current window frames
    -- via :getWindows(), then :subscribe({windowMoved[, windowsChanged]}, fn) so fn(win)
    -- fires whenever a window moves/resizes; teardown is :unsubscribeAll().
    --
    -- ============================ UNVERIFIED SCAFFOLD ============================
    -- PARSE-checked only. The SetWinEventHook wiring is modelled on foundation's LL
    -- keyboard/mouse hooks (same OUT_OF_CONTEXT + host.run message-pump delivery + the
    -- keep()-anchor-forever callback rule) but has NEVER run on Windows. RISK notes
    -- inline. Fails soft: a hook that won't install just means no window events, never a
    -- crash (the recorder's per-event work is pcall'd on the mudscript side).
    -- ============================================================================
    --
    -- Contract mudscript consumes (the whole surface we implement):
    --   hs.window.filter.new(nil)            -> filter        (nil = unfiltered/all)
    --   hs.window.filter.windowMoved         -- event token (also .windowsChanged etc.)
    --   filter:getWindows()                  -> { hs.window, ... }
    --   filter:subscribe(events, fn)         -- fn(win, appName, event) per event
    --   filter:unsubscribeAll()              -- remove every installed hook
    --
    -- Delivery: SetWinEventHook(OUT_OF_CONTEXT) posts events to the INSTALLING thread's
    -- message queue; foundation's single runloop (host.run) already pumps it with
    -- PeekMessage/DispatchMessage, so events arrive with no extra loop (frozen shared
    -- rule). We add WINEVENT_SKIPOWNPROCESS so the user dragging OUR OWN shell/alerts
    -- never generates recorder events.
-- END --

local ffi    = require("ffi")
local bit    = require("bit")
local host   = require("hs.foundation")
local window = require("hs.window")

local U = host.C.user32

-- Own cdefs (foundation owns HWND/DWORD/LONG/HMODULE; we add the WinEvent surface). --
    ffi.cdef([[
typedef void* HWINEVENTHOOK;
typedef void (__stdcall *WINEVENTPROC)(HWINEVENTHOOK, DWORD, HWND, LONG, LONG, DWORD, DWORD);
HWINEVENTHOOK SetWinEventHook(DWORD, DWORD, HMODULE, WINEVENTPROC, DWORD, DWORD, DWORD);
BOOL UnhookWinEvent(HWINEVENTHOOK);
]])
-- END --

-- Win32 event constants --
    -- EVENT_SYSTEM_MOVESIZEEND fires ONCE when an interactive move/resize completes --
    -- exactly the granularity the recorder wants (vs EVENT_OBJECT_LOCATIONCHANGE which
    -- floods per pixel). CREATE/DESTROY back windowsChanged.
    local EVENT_SYSTEM_FOREGROUND  = 0x0003
    local EVENT_SYSTEM_MOVESIZEEND = 0x000B
    local EVENT_OBJECT_CREATE      = 0x8000
    local EVENT_OBJECT_DESTROY     = 0x8001

    local OBJID_WINDOW             = 0        -- deliver only real top-level windows
    local WINEVENT_OUTOFCONTEXT    = 0x0000
    local WINEVENT_SKIPOWNPROCESS  = 0x0002
-- END --

-- Public event tokens (strings, like real HS) + their Win32 event codes --
    local filter = {}

    filter.windowCreated   = "windowCreated"
    filter.windowDestroyed = "windowDestroyed"
    filter.windowMoved     = "windowMoved"
    filter.windowResized   = "windowResized"    -- MOVESIZEEND covers both move & resize
    filter.windowFocused   = "windowFocused"
    filter.windowsChanged  = "windowsChanged"

    local EVENT_CODES = {
        windowCreated   = { EVENT_OBJECT_CREATE },
        windowDestroyed = { EVENT_OBJECT_DESTROY },
        windowMoved     = { EVENT_SYSTEM_MOVESIZEEND },
        windowResized   = { EVENT_SYSTEM_MOVESIZEEND },
        windowFocused   = { EVENT_SYSTEM_FOREGROUND },
        windowsChanged  = { EVENT_OBJECT_CREATE, EVENT_OBJECT_DESTROY },
    }
-- END --

-- keep(): anchor every ffi.cast callback + HWINEVENTHOOK for process life. A collected
-- WinEventProc that the OS later calls is a hard crash (foundation's #1 footgun). We
-- release hooks via UnhookWinEvent in unsubscribeAll but NEVER drop the cast.
    local ALIVE = {}
    local function keep(x) ALIVE[#ALIVE + 1] = x; return x end
-- END --

-- Filter object --
    local Filter = {}
    Filter.__index = Filter

    -- getWindows(): the currently-allowed windows. nil filter = all standard windows,
    -- which hs.window.allWindows() already computes (visible, titled top-level set).
    function Filter:getWindows()
        local ok, list = pcall(window.allWindows)
        if not ok or type(list) ~= "table" then return {} end
        return list
    end

    -- subscribe(events, fn): events is a token or list of tokens; fn(win, appName,
    -- event) fires per matching Win32 event. One SetWinEventHook per distinct event
    -- code (min==max keeps each hook narrow -- no wide-range noise). Additive: may be
    -- called more than once.
    function Filter:subscribe(events, fn)
        if type(events) == "string" then events = { events } end
        if type(events) ~= "table" or type(fn) ~= "function" then return self end

        -- Collect the distinct Win32 codes these tokens map to.
        local wanted = {}
        for _, tok in ipairs(events) do
            local codes = EVENT_CODES[tok]
            if codes then for _, c in ipairs(codes) do wanted[c] = true end end
        end

        for code in pairs(wanted) do
            -- One proc per hook, closing over fn. idObject/idChild gate to the window
            -- itself (OBJID_WINDOW, no child controls). hwnd may be nil for some
            -- system events -- skip those.
            local proc = keep(ffi.cast("WINEVENTPROC",
                function(_hook, event, hwnd, idObject, idChild, _thr, _time)
                    if idObject ~= OBJID_WINDOW or idChild ~= 0 then return end
                    if hwnd == nil then return end
                    -- Never throw across the FFI boundary out of an OS callback.
                    pcall(function()
                        local win = window._newWindow(ffi.cast("HWND", hwnd))
                        local appName
                        pcall(function()
                            local app = win:application()
                            if app then appName = app:name() end
                        end)
                        fn(win, appName, event)
                    end)
                end))
            -- hmodWinEventProc MUST be nil for an OUT_OF_CONTEXT Lua callback (there is
            -- no DLL to name); idProcess/idThread 0 = system-wide. SKIPOWNPROCESS drops
            -- our own windows so the recorder never captures the shell moving.
            local hook = U.SetWinEventHook(code, code, nil, proc, 0, 0,
                bit.bor(WINEVENT_OUTOFCONTEXT, WINEVENT_SKIPOWNPROCESS))
            if hook ~= nil then
                self._hooks[#self._hooks + 1] = keep(hook)
            end
        end
        return self
    end

    -- unsubscribeAll(): remove every hook this filter installed. The cast procs stay in
    -- ALIVE (never safe to reclaim), but UnhookWinEvent stops future callbacks.
    function Filter:unsubscribeAll()
        for _, hook in ipairs(self._hooks) do
            pcall(function() U.UnhookWinEvent(hook) end)
        end
        self._hooks = {}
        return self
    end
    Filter.unsubscribe = Filter.unsubscribeAll   -- HS also has :unsubscribe(); alias
-- END --

-- hs.window.filter.new(fn) -> filter. fn is ignored here (nil = unfiltered, the only
-- form mudscript uses); a real predicate would gate getWindows()/emitted events.
    function filter.new(_fn)
        return setmetatable({ _hooks = {} }, Filter)
    end
-- END --

return filter
