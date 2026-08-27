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
    --   controller:setCallback(fn)   -- fn({ body = posted string, name = channel })
    --                                   per posted message (the WKWebView message shape)
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

    -- setCallback(fn): fn is invoked as fn({ body = <posted string>, name = <channel> })
    -- for each message the page posts -- the Hammerspoon/WKWebView message-table shape
    -- (consumers read message.body). Returns self for chaining. Passing nil clears it.
    function Controller:setCallback(fn)
        self._callback = fn
        return self
    end

    -- _deliver(rawString): PRIVATE seam called by hs.webview from the WebMessageReceived
    -- handler with the RAW page string. The callback is invoked with a Hammerspoon-
    -- SHAPED message TABLE, not the bare string: real WKWebView usercontent handlers
    -- receive { body = <posted value>, name = <handler name>, ... }, and every mac/
    -- consumer reads `message.body` (ms_shell/ms_loading/ms_devtools/ms_guardian/
    -- ms_settings). Delivering the bare string left `message.body` nil, so their
    -- json.decode saw "" and every bridge message was silently dropped -- which is
    -- exactly why the shell's `ready` handshake timed out. `.body` is the string the
    -- page posted; consumers hs.json.decode it themselves.
    -- Guarded so a throwing consumer callback can never unwind across the FFI boundary
    -- in the parent's Invoke (a throw there is a hard crash).
    function Controller:_deliver(rawString)
        local fn = self._callback
        if not fn then return end
        local msg = { body = rawString, name = self._name }
        local ok, err = pcall(fn, msg)
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
