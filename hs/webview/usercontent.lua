-- hs.webview.usercontent  (user-content controller, submodule of hs.webview) --
    -- The JS -> Lua half of the bridge. In Hammerspoon (WKWebView) this object owns
    -- injected user scripts and named message handlers; the page posts to a handler by
    -- name via window.webkit.messageHandlers.<name>.postMessage(...). mudscript only
    -- ever uses ONE piece of that surface: a single named channel with a setCallback.
    --
    -- On WebView2 the transport is different -- the page calls
    -- window.chrome.webview.postMessage(s), which surfaces as a single
    -- WebMessageReceived event stream on the CoreWebView2. There is exactly one such
    -- stream per view, so this controller is really just a NAMED holder for one Lua
    -- callback; hs.webview wires that stream to controller:_deliver(string) when it
    -- constructs the view with this controller attached.
    --
    -- Consumer demand is the whole API here (nothing more is used by mudscript):
    --   hs.webview.usercontent.new(name) -> controller
    --   controller:setCallback(fn)   -- fn(messageString) per posted message
    --
    -- Deliberately ABSENT (unused by the consumer, so not scaffolded): injectScript,
    -- addUserScript, removeAllUserScripts. Add them only if a real caller appears.
    --
    -- Pure Lua: no FFI, no Win32. All COM/transport lives in hs.webview; this file is
    -- just the callback contract the parent module delivers into.
-- END --

local usercontent = {}

-- Controller object --
    local Controller = {}
    Controller.__index = Controller

    -- setCallback(fn): fn is invoked as fn(message) per posted message. CRITICAL: in
    -- real Hammerspoon (WKScriptMessage_toLua) `message` is a TABLE, not the raw
    -- string -- { body = <payload>, name = <channel>, frameInfo, webView } -- and
    -- consumers read `message.body` (mudscript ms_shell.lua's shell callback does
    -- exactly `tostring(message.body)` then json.decode). We MUST deliver that same
    -- shape (see _deliver); delivering a bare string makes `message.body` nil, the
    -- decode fail, and EVERY message (including the `ready` handshake) get dropped --
    -- which strands the shell at the 1.5s force-open fallback. Returns self for
    -- chaining. Passing nil clears it.
    function Controller:setCallback(fn)
        self._callback = fn
        return self
    end

    -- _deliver(rawString): PRIVATE seam called by hs.webview from the
    -- WebMessageReceived handler with the raw string the page posted. We wrap it into
    -- the Hammerspoon WKScriptMessage table shape (body/name) so a mudscript callback
    -- written to the real HS contract works unchanged on WebView2. Guarded so a
    -- throwing consumer callback can never unwind across the FFI boundary in the
    -- parent's Invoke (a throw there is a hard crash).
    function Controller:_deliver(rawString)
        local fn = self._callback
        if not fn then return end
        local message = { body = rawString, name = self._name }
        local ok, err = pcall(fn, message)
        if not ok then
            io.stderr:write("hs.webview.usercontent callback error: " .. tostring(err) .. "\n")
        end
    end

    -- name(): the channel name this controller was created with (identification only).
    function Controller:name()
        return self._name
    end
-- END --

-- hs.webview.usercontent.new(name) -> controller --
    function usercontent.new(name)
        return setmetatable({
            _name     = name,
            _callback = nil,
        }, Controller)
    end
-- END --

return usercontent
