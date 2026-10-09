-- hs.socket: non-blocking Winsock TCP, AF_UNIX and UDP sockets polled from one runloop timer. startTLS is unsupported and returns nil plus a message.

local host = require("hs.foundation")
local ffi  = host.ffi

-- Winsock FFI --
    local WS = ffi.load("ws2_32")

    local decls = {
        "typedef uintptr_t SOCKET;",
        "typedef struct addrinfo { int ai_flags; int ai_family; int ai_socktype; int ai_protocol; size_t ai_addrlen; char* ai_canonname; void* ai_addr; struct addrinfo* ai_next; } addrinfo;",
        "typedef struct { unsigned int fd_count; SOCKET fd_array[64]; } ws_fd_set;",
        "typedef struct { long tv_sec; long tv_usec; } ws_timeval;",
        "int WSAStartup(unsigned short, void*);",
        "int WSAGetLastError(void);",
        "SOCKET socket(int, int, int);",
        "int connect(SOCKET, const void*, int);",
        "int send(SOCKET, const char*, int, int);",
        "int recv(SOCKET, char*, int, int);",
        "int closesocket(SOCKET);",
        "int ioctlsocket(SOCKET, long, unsigned long*);",
        "int getaddrinfo(const char*, const char*, const addrinfo*, addrinfo**);",
        "void freeaddrinfo(addrinfo*);",
        "int select(int, ws_fd_set*, ws_fd_set*, ws_fd_set*, const ws_timeval*);",
        "int bind(SOCKET, const void*, int);",
        "int listen(SOCKET, int);",
        "SOCKET accept(SOCKET, void*, int*);",
        "int sendto(SOCKET, const char*, int, int, const void*, int);",
        "int recvfrom(SOCKET, char*, int, int, void*, int*);",
        "int getsockname(SOCKET, void*, int*);",
        "int getpeername(SOCKET, void*, int*);",
        "int setsockopt(SOCKET, int, int, const char*, int);"
    }

    for _, d in ipairs(decls) do
        pcall(ffi.cdef, d)
    end
-- END --

-- Constants --
    local AF_INET        = 2
    local AF_UNIX        = 1
    local SOCK_STREAM    = 1
    local SOCK_DGRAM     = 2
    local SOL_SOCKET     = 0xFFFF
    local SO_REUSEADDR   = 4
    local SO_BROADCAST   = 0x20
    local FIONBIO        = -2147195266
    local WSAEWOULDBLOCK = 10035
    local AI_PASSIVE     = 1
    local POLL_MS        = 10
    local CHUNK          = 65536
    local INVALID        = ffi.cast("SOCKET", ffi.cast("intptr_t", -1))
-- END --

local socket = {
    timeout = -1
}

local socketMT = {}
socketMT.__index = socketMT

local udpMT = {}
udpMT.__index = udpMT

socket.udp = {}

-- Shared helpers --
    local started = false

    local function ensureWSA()
        if started then return true end

        local data = ffi.new("char[512]")
        if WS.WSAStartup(0x0202, data) ~= 0 then return false end

        started = true

        return true
    end

    local function lastError()
        return WS.WSAGetLastError()
    end

    local function guard(fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok then
            io.stderr:write("hs.socket callback error: " .. tostring(err) .. "\n")
        end
    end

    local function newSock(family, kind)
        local s = WS.socket(family, kind, 0)
        if s == INVALID then return nil end

        local nb = ffi.new("unsigned long[1]", 1)
        WS.ioctlsocket(s, FIONBIO, nb)

        return s
    end

    local function unixAddr(path)
        local buf = ffi.new("char[110]")
        ffi.cast("uint16_t*", buf)[0] = AF_UNIX
        ffi.copy(buf + 2, path, math.min(#path, 107))

        return buf, 110
    end

    local function resolve(hostName, port, kind, passive)
        local hints = ffi.new("addrinfo[1]")
        hints[0].ai_family = AF_INET
        hints[0].ai_socktype = kind
        hints[0].ai_flags = passive and AI_PASSIVE or 0

        local res = ffi.new("addrinfo*[1]")
        if WS.getaddrinfo(hostName, tostring(port), hints, res) ~= 0 then return nil end

        local ai = res[0]
        local len = tonumber(ai.ai_addrlen)
        local buf = ffi.new("char[?]", len)
        ffi.copy(buf, ai.ai_addr, len)
        WS.freeaddrinfo(res[0])

        return buf, len
    end

    local function addrToTable(buf, len)
        local family = ffi.cast("uint16_t*", buf)[0]
        if family == AF_INET then
            local b = ffi.cast("uint8_t*", buf)

            return {
                addressFamily = "AF_INET",
                host = string.format("%d.%d.%d.%d", b[4], b[5], b[6], b[7]),
                port = b[2] * 256 + b[3]
            }
        end

        if family == AF_UNIX then
            return {
                addressFamily = "AF_UNIX",
                host = ffi.string(buf + 2)
            }
        end

        return nil
    end

    local function nameOf(fnName, sock)
        local buf = ffi.new("char[128]")
        local len = ffi.new("int[1]", 128)
        if WS[fnName](sock, buf, len) ~= 0 then return nil end

        return addrToTable(buf, len[0])
    end

    local function reuse(sock)
        local one = ffi.new("int[1]", 1)
        WS.setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, ffi.cast("const char*", one), 4)
    end
-- END --

-- Poll loop --
    local live = {}
    local ticker = nil

    local function tick()
        local snapshot = {}
        for obj in pairs(live) do
            snapshot[#snapshot + 1] = obj
        end

        for _, obj in ipairs(snapshot) do
            if live[obj] then guard(obj._poll, obj) end
        end
    end

    local function track(obj)
        live[obj] = true

        if not ticker then
            ticker = host.schedule(POLL_MS, tick, POLL_MS)
        end
    end

    local function untrack(obj)
        live[obj] = nil

        if ticker and next(live) == nil then
            ticker:cancel()
            ticker = nil
        end
    end
-- END --

-- TCP and Unix sockets --
    local function build(callback)
        return setmetatable({
            _sock = nil,
            _state = "idle",
            _callback = callback,
            _timeout = socket.timeout,
            _buf = "",
            _reads = {},
            _writes = {},
            _children = {},
            _unixPath = nil,
            _onConnect = nil,
            _deadline = nil
        }, socketMT)
    end

    function socket.new(callback)
        ensureWSA()

        return build(callback)
    end

    function socket.server(target, callback)
        local s = socket.new(callback)

        return s:listen(target)
    end

    function socket.parseAddress(raw)
        if type(raw) ~= "string" or #raw < 8 then return nil end

        local buf = ffi.new("char[?]", #raw)
        ffi.copy(buf, raw, #raw)

        return addrToTable(buf, #raw)
    end

    function socketMT:setCallback(callback)
        self._callback = callback

        return self
    end

    function socketMT:setTimeout(seconds)
        self._timeout = seconds

        return self
    end

    function socketMT:connected()
        return self._state == "connected"
    end

    function socketMT:connections()
        local count = 0

        for _, child in ipairs(self._children) do
            if child._state == "connected" then count = count + 1 end
        end

        return count
    end

    function socketMT:info()
        local info = {
            isConnected = self._state == "connected",
            isDisconnected = self._state == "idle",
            isServer = self._state == "listening",
            isIPv4 = self._unixPath == nil,
            isIPv6 = false
        }

        if self._sock then
            local peer = nameOf("getpeername", self._sock)
            local mine = nameOf("getsockname", self._sock)

            if peer then
                info.connectedAddress = peer.host
                info.connectedPort = peer.port
            end

            if mine then
                info.localAddress = mine.host
                info.localPort = mine.port
            end
        end

        return info
    end

    function socketMT:startTLS()
        return nil, "TLS is not supported"
    end

    -- Opens the connection and calls fn once it completes
    function socketMT:connect(target, a, b)
        local port, fn = nil, nil
        if type(a) == "number" then
            port, fn = a, b
        else
            fn = a
        end

        if self._state ~= "idle" then return self end
        if not ensureWSA() then return self end

        local sock, addr, len

        if port then
            addr, len = resolve(target, port, SOCK_STREAM, false)
            sock = addr and newSock(AF_INET, SOCK_STREAM)
        else
            addr, len = unixAddr(target)
            sock = newSock(AF_UNIX, SOCK_STREAM)
            self._unixPath = target
        end

        if not sock then return self end

        local rc = WS.connect(sock, addr, len)
        if rc ~= 0 and lastError() ~= WSAEWOULDBLOCK then
            WS.closesocket(sock)

            return self
        end

        self._sock = sock
        self._state = "connecting"
        self._onConnect = fn

        if self._timeout >= 0 then
            self._deadline = host.now() + self._timeout * 1000
        end

        track(self)

        return self
    end

    -- Binds and listens on a TCP port or a Unix path
    function socketMT:listen(target)
        if self._state ~= "idle" then return self end
        if not ensureWSA() then return self end

        local sock, addr, len

        if type(target) == "number" then
            addr, len = resolve("0.0.0.0", target, SOCK_STREAM, true)
            sock = addr and newSock(AF_INET, SOCK_STREAM)
        else
            os.remove(target)
            addr, len = unixAddr(target)
            sock = newSock(AF_UNIX, SOCK_STREAM)
            self._unixPath = target
        end

        if not sock then return self end

        if type(target) == "number" then reuse(sock) end

        if WS.bind(sock, addr, len) ~= 0 or WS.listen(sock, 16) ~= 0 then
            WS.closesocket(sock)
            self._unixPath = nil

            return self
        end

        self._sock = sock
        self._state = "listening"

        track(self)

        return self
    end

    -- Closes the socket, drops pending operations and closes accepted children
    function socketMT:disconnect()
        if self._sock then
            WS.closesocket(self._sock)
            self._sock = nil
        end

        for _, child in ipairs(self._children) do
            child:disconnect()
        end

        if self._state == "listening" and self._unixPath then
            os.remove(self._unixPath)
        end

        self._children = {}
        self._reads = {}
        self._writes = {}
        self._buf = ""
        self._state = "idle"
        self._deadline = nil

        untrack(self)

        return self
    end

    -- Queues a read for a delimiter string or a byte count
    function socketMT:read(what, tag)
        if self._state == "listening" then
            for _, child in ipairs(self._children) do
                if child._state == "connected" then child:read(what, tag) end
            end

            return self
        end

        local op = { tag = tag }

        if type(what) == "number" then
            op.length = what
        else
            op.delim = what
        end

        if self._timeout >= 0 then
            op.deadline = host.now() + self._timeout * 1000
        end

        self._reads[#self._reads + 1] = op

        return self
    end

    -- Queues data and calls fn(tag) once every byte is sent
    function socketMT:write(message, tag, fn)
        if self._state == "listening" then
            for _, child in ipairs(self._children) do
                if child._state == "connected" then child:write(message, tag, fn) end
            end

            return self
        end

        local op = {
            data = tostring(message),
            sent = 0,
            tag = tag,
            fn = fn
        }

        if self._timeout >= 0 then
            op.deadline = host.now() + self._timeout * 1000
        end

        self._writes[#self._writes + 1] = op

        return self
    end

    function socketMT:_flush()
        while self._writes[1] do
            local op = self._writes[1]
            local rest = #op.data - op.sent
            local n = WS.send(self._sock, ffi.cast("const char*", op.data) + op.sent, rest, 0)

            if n < 0 then
                if lastError() == WSAEWOULDBLOCK then return true end

                return false
            end

            op.sent = op.sent + n

            if op.sent < #op.data then return true end

            table.remove(self._writes, 1)

            if op.fn then guard(op.fn, op.tag) end
        end

        return true
    end

    function socketMT:_fill()
        local buf = ffi.new("char[?]", CHUNK)

        while true do
            local n = WS.recv(self._sock, buf, CHUNK, 0)

            if n > 0 then
                self._buf = self._buf .. ffi.string(buf, n)
            elseif n == 0 then
                return false
            else
                return lastError() == WSAEWOULDBLOCK
            end
        end
    end

    function socketMT:_deliver()
        while self._reads[1] and self._state == "connected" do
            local op = self._reads[1]
            local chunk = nil

            if op.length then
                if #self._buf >= op.length then
                    chunk = self._buf:sub(1, op.length)
                    self._buf = self._buf:sub(op.length + 1)
                end
            else
                local at = self._buf:find(op.delim, 1, true)
                if at then
                    local stop = at + #op.delim - 1
                    chunk = self._buf:sub(1, stop)
                    self._buf = self._buf:sub(stop + 1)
                end
            end

            if not chunk then return end

            table.remove(self._reads, 1)

            if self._callback then guard(self._callback, chunk, op.tag) end
        end
    end

    function socketMT:_expired()
        local now = host.now()

        if self._deadline and now >= self._deadline then return true end

        local r = self._reads[1]
        if r and r.deadline and now >= r.deadline then return true end

        local w = self._writes[1]
        if w and w.deadline and now >= w.deadline then return true end

        return false
    end

    function socketMT:_accept()
        while true do
            local buf = ffi.new("char[128]")
            local len = ffi.new("int[1]", 128)
            local s = WS.accept(self._sock, buf, len)

            if s == INVALID then return end

            local nb = ffi.new("unsigned long[1]", 1)
            WS.ioctlsocket(s, FIONBIO, nb)

            local child = build(self._callback)
            child._sock = s
            child._state = "connected"
            child._timeout = self._timeout
            child._unixPath = self._unixPath

            self._children[#self._children + 1] = child

            track(child)
        end
    end

    function socketMT:_poll()
        if self._state == "listening" then
            self:_accept()

            return
        end

        if self._state == "connecting" then
            local w = ffi.new("ws_fd_set")
            w.fd_count = 1
            w.fd_array[0] = self._sock

            local e = ffi.new("ws_fd_set")
            e.fd_count = 1
            e.fd_array[0] = self._sock

            local tv = ffi.new("ws_timeval", { 0, 0 })
            WS.select(0, nil, w, e, tv)

            if e.fd_count > 0 then
                self:disconnect()
            elseif w.fd_count > 0 then
                self._state = "connected"
                self._deadline = nil

                if self._onConnect then guard(self._onConnect) end
            elseif self:_expired() then
                self:disconnect()
            end

            return
        end

        if self._state ~= "connected" then return end

        local alive = self:_flush()
        local open = self:_fill()

        self:_deliver()

        if not alive or not open or self:_expired() then
            self:disconnect()
        end
    end
-- END --

-- UDP --
    function socket.udp.new(callback)
        ensureWSA()

        return setmetatable({
            _sock = nil,
            _callback = callback,
            _receiving = false,
            _port = nil
        }, udpMT)
    end

    function udpMT:setCallback(callback)
        self._callback = callback

        return self
    end

    function udpMT:_open()
        if self._sock then return true end

        self._sock = newSock(AF_INET, SOCK_DGRAM)

        return self._sock ~= nil
    end

    -- Binds the local port and starts receiving
    function udpMT:listen(port)
        if not ensureWSA() or not self:_open() then return self end

        local addr, len = resolve("0.0.0.0", port, SOCK_DGRAM, true)
        if not addr then return self end

        reuse(self._sock)

        if WS.bind(self._sock, addr, len) ~= 0 then return self end

        self._port = port
        self._receiving = true

        track(self)

        return self
    end

    function udpMT:receive()
        self._receiving = true

        if self._sock then track(self) end

        return self
    end

    function udpMT:pause()
        self._receiving = false

        untrack(self)

        return self
    end

    function udpMT:broadcast(enabled)
        if self:_open() then
            local v = ffi.new("int[1]", enabled == false and 0 or 1)
            WS.setsockopt(self._sock, SOL_SOCKET, SO_BROADCAST, ffi.cast("const char*", v), 4)
        end

        return self
    end

    function udpMT:send(message, hostName, port, tag)
        if not self:_open() then return self end

        local addr, len = resolve(hostName, port, SOCK_DGRAM, false)
        if not addr then return self end

        local data = tostring(message)
        WS.sendto(self._sock, data, #data, 0, addr, len)

        return self
    end

    function udpMT:info()
        local mine = self._sock and nameOf("getsockname", self._sock)

        return {
            localAddress = mine and mine.host,
            localPort = mine and mine.port,
            isOpen = self._sock ~= nil
        }
    end

    function udpMT:close()
        if self._sock then
            WS.closesocket(self._sock)
            self._sock = nil
        end

        self._receiving = false

        untrack(self)

        return self
    end

    function udpMT:_poll()
        if not self._sock or not self._receiving then return end

        local buf = ffi.new("char[?]", CHUNK)

        while true do
            local from = ffi.new("char[128]")
            local flen = ffi.new("int[1]", 128)
            local n = WS.recvfrom(self._sock, buf, CHUNK, 0, from, flen)

            if n < 0 then return end

            if self._callback then
                guard(self._callback, ffi.string(buf, n), ffi.string(from, flen[0]))
            end
        end
    end
-- END --

return socket
