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
