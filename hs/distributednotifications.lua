-- hs.distributednotifications  (Win32 WM_COPYDATA broadcast backend) --
    -- Hammerspoon's hs.distributednotifications wraps NSDistributedNotificationCenter:
    -- a machine-wide, cross-PROCESS pub/sub bus. A post() in one process is delivered
    -- to matching observers in every other process on the session.
    --
    -- Windows has no single system notification bus with those semantics, so this is
    -- built from scratch on the closest faithful primitive: a registered window class
    -- plus WM_COPYDATA. Every process that observes owns one hidden message-only
    -- window of the shared class HammerspoonDistNot. post() serialises the
    -- notification to JSON, enumerates every window of that class across the session
    -- with FindWindowExA, and SendMessageTimeout()s each one a WM_COPYDATA carrying
    -- the payload -- the kernel marshals the buffer across the process boundary. Each
    -- receiver's wndproc decodes it and fans out to its local observers.
    --
    -- REACH: any process running this port (or any app that adopts the class + dwData
    -- tag) on the same desktop session. It cannot reach macOS apps (none exist here)
    -- nor arbitrary Windows apps that do not speak the convention -- nothing could.
    -- Like the real thing, delivery is best-effort: SendMessageTimeout uses
    -- SMTO_ABORTIFHUNG so one wedged peer can't stall a post.
    --
    -- Contract honoured (parity with libdistributednotifications.m):
    --   hs.distributednotifications.new(callback[, name[, object]]) -> watcher
    --       callback(name, object, userInfo)   -- fired on a matching post
    --     :start()   -- begin observing (creates the shared window lazily); returns self
    --     :stop()    -- stop observing; returns self
    --     :__tostring
    --   hs.distributednotifications.post(name[, sender[, userInfo]])
    --
    -- A nil watcher name matches every notification; a nil object matches every
    -- sender (same filtering as NSDistributedNotificationCenter addObserver:).
    --
    -- CDEF OWNERSHIP: base window types + WNDCLASSEXA come from hs.foundation;
    -- RegisterClassExA/CreateWindowExA/DefWindowProcA come from hs.menubar (required
    -- below, as hs.notify does). This module OWNS the symbols nothing else declares:
    -- FindWindowExA, SendMessageTimeoutA, and the COPYDATASTRUCT struct.
-- END --

local ffi = require("ffi")

local host = require("hs.foundation")
require("hs.menubar")           -- owns RegisterClassExA / CreateWindowExA / DefWindowProcA
local json = require("hs.json")

local U     = host.C.user32
local hInst = host.moduleHandle

-- Own FFI surface (symbols nothing else declares) --
    ffi.cdef[[
typedef struct { uintptr_t dwData; uint32_t cbData; void *lpData; } COPYDATASTRUCT;
HWND    FindWindowExA(HWND, HWND, LPCSTR, LPCSTR);
LRESULT SendMessageTimeoutA(HWND, UINT, WPARAM, LPARAM, UINT, UINT, uintptr_t*);
]]
-- END --

-- Constants --
    local WM_COPYDATA      = 0x004A
    local SMTO_ABORTIFHUNG = 0x0002
    local SEND_TIMEOUT_MS  = 120          -- per-peer ceiling; a hung peer is skipped
    -- Tag in COPYDATASTRUCT.dwData so a stray WM_COPYDATA from anything else that
    -- happened onto our class is ignored. 'MSDN' = MudSpoon Distributed Notification.
    local MAGIC            = 0x4D53444E
    -- The receiver is a hidden top-level window, NOT a message-only (HWND_MESSAGE)
    -- one: post() discovers peers with a top-level FindWindowExA(nil, ...) walk, and
    -- that walk does not enumerate message-only windows. WS_EX_TOOLWINDOW + never
    -- calling ShowWindow keeps it off screen, out of the taskbar and out of Alt-Tab.
    local WS_EX_TOOLWINDOW = 0x00000080
    local CLASS            = "HammerspoonDistNot"
-- END --

-- Live observers in THIS process. A started watcher is strongly referenced here
-- (as NSDistributedNotificationCenter retains its observers), so it stays alive
-- until :stop(); that is also why a table watcher needs no __gc on LuaJIT.
local observers = {}

-- Deliver one decoded note to every matching local observer. Called from the
-- wndproc, so it must never let an error escape across the FFI boundary.
local function dispatch(note)
    if type(note) ~= "table" or type(note.name) ~= "string" then return end
    for w in pairs(observers) do
        if (w.name == nil or w.name == note.name)
            and (w.object == nil or w.object == note.object) then
            pcall(w.fn, note.name, note.object, note.userInfo)
        end
    end
end

-- Shared hidden message window (lazy: only when this process first observes) --
    -- jit.off: a callback body must never be JIT-traced -- an error unwinding out of
    -- compiled mcode across the FFI boundary panics LuaJIT (see hs.foundation).
    local function wndProcFn(hwnd, msg, wp, lp)
        if msg == WM_COPYDATA then
            local cds = ffi.cast("COPYDATASTRUCT*", lp)
            if cds.dwData == MAGIC and cds.lpData ~= nil and cds.cbData > 0 then
                local ok, note = pcall(function()
                    return json.decode(ffi.string(cds.lpData, cds.cbData))
                end)
                if ok then dispatch(note) end
            end
            return 1                       -- TRUE: message processed
        end
        return U.DefWindowProcA(hwnd, msg, wp, lp)
    end
    jit.off(wndProcFn, true)
    local wndProc = ffi.cast("WNDPROC", wndProcFn)

    local classBuf = ffi.new("char[?]", #CLASS + 1)
    ffi.copy(classBuf, CLASS)

    local win, classReady
    local function ensureWindow()
        if win then return win end
        if not classReady then
            local wc = ffi.new("WNDCLASSEXA")
            wc.cbSize        = ffi.sizeof("WNDCLASSEXA")
            wc.lpfnWndProc   = wndProc
            wc.hInstance     = hInst
            wc.lpszClassName = classBuf
            -- RegisterClassExA returns 0 if the class already exists; that is fine on
            -- a re-entry, but a genuine first-time failure must surface.
            U.RegisterClassExA(wc)
            classReady = true
        end
        -- hidden, zero-size, top-level (parent nil), never shown.
        win = U.CreateWindowExA(WS_EX_TOOLWINDOW, classBuf, "", 0, 0, 0, 0, 0, nil, nil, hInst, nil)
        if win == nil then error("hs.distributednotifications: CreateWindowExA failed") end
        return win
    end
-- END --

-- Module: post --
    --- hs.distributednotifications.post(name[, sender[, userInfo]])
    --- Broadcasts a notification to every observing process on the session.
    local function post(name, sender, userInfo)
        if type(name) ~= "string" then
            error("hs.distributednotifications.post: name must be a string", 2)
        end
        local payload = { name = name }
        if sender ~= nil then payload.object = sender end
        if userInfo ~= nil then payload.userInfo = userInfo end

        local body = json.encode(payload)
        local buf  = ffi.new("char[?]", #body)
        ffi.copy(buf, body, #body)

        local cds = ffi.new("COPYDATASTRUCT")
        cds.dwData = MAGIC
        cds.cbData = #body
        cds.lpData = buf

        local selfHwnd = win            -- nil if this process never observes; harmless
        local resultBuf = ffi.new("uintptr_t[1]")
        -- Walk every top-level window of our class across ALL processes. FindWindowExA
        -- with a class filter and a rolling `after` handle enumerates them; a matching
        -- window in our own process (if any) receives the post too, mirroring
        -- NSDistributedNotificationCenter delivering a post to local observers.
        local h = U.FindWindowExA(nil, nil, classBuf, nil)
        while h ~= nil do
            U.SendMessageTimeoutA(h, WM_COPYDATA,
                ffi.cast("WPARAM", selfHwnd or 0),
                ffi.cast("LPARAM", cds),
                SMTO_ABORTIFHUNG, SEND_TIMEOUT_MS, resultBuf)
            h = U.FindWindowExA(nil, h, classBuf, nil)
        end
    end
-- END --

-- Watcher object (new / start / stop) --
    local watcherMT = {}
    watcherMT.__index = watcherMT

    function watcherMT:start()
        ensureWindow()
        observers[self] = true
        return self
    end

    function watcherMT:stop()
        observers[self] = nil
        return self
    end

    function watcherMT:__tostring()
        return string.format("hs.distributednotifications: name: %s object: %s",
            tostring(self.name), tostring(self.object))
    end

    --- hs.distributednotifications.new(callback[, name[, object]]) -> watcher
    --- callback(name, object, userInfo) fires on a matching post. A nil name
    --- observes every notification; a nil object observes every sender.
    local function new(callback, name, object)
        if type(callback) ~= "function" then
            error("hs.distributednotifications.new: callback must be a function", 2)
        end
        if name ~= nil and type(name) ~= "string" then
            error("hs.distributednotifications.new: name must be a string or nil", 2)
        end
        if object ~= nil and type(object) ~= "string" then
            error("hs.distributednotifications.new: object must be a string or nil", 2)
        end
        return setmetatable({ fn = callback, name = name, object = object }, watcherMT)
    end
-- END --

return { new = new, post = post }
