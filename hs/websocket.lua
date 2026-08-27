-- hs.websocket  (RFC 6455 client over Winsock via LuaJIT FFI) --
    -- A Hammerspoon-shaped hs.websocket client, built on a raw non-blocking Winsock
    -- (ws2_32) socket. The slice mudscript actually uses:
    --   hs.websocket.new(url, callback)   -- callback(event, message)
    --   ws:send(message)                  -- sends a text frame
    --   ws:close()                        -- closes the connection
    -- callback `event` is one of: "open", "received", "closed", "fail", "pong"
    -- (Hammerspoon's status strings). "received" carries the message payload.
    --
    -- ------------------------- Single-thread integration --------------------------
    -- mudspoon is ONE thread + ONE message pump (hs.foundation). This client owns NO
    -- thread and installs NO loop: the socket is non-blocking and every stage --
    -- connect completion, the HTTP upgrade handshake, and frame I/O -- is advanced
    -- from a repeating host.schedule() tick, exactly like hs.task polls its child.
    -- new() returns synchronously; "open" arrives on a later tick.
    --
    -- Depends on hs.foundation for its bit library and the ONE runloop only. Winsock
    -- and its structs are unique to this module, so the entire FFI surface below is
    -- ours to cdef; nothing here re-declares a foundation type.
    --
    -- --------------------------------- SHORTCUTS ----------------------------------
    --  * TLS / wss:// is NOT implemented. A wss:// URL fails immediately with an
    --    ("fail", "...") callback -- there is no Schannel/OpenSSL handshake here.
    --    ws:// is sufficient for the localhost/LAN bridge mudscript uses.
    --  * The Sec-WebSocket-Accept response header is NOT validated (that needs SHA-1).
    --    We only require the "101" status line -- adequate for a trusted local peer.
    --  * Received-frame reassembly supports continuation frames and 64-bit lengths up
    --    to the low 32 bits; a single message is buffered whole before "received".
    --
    -- UNVERIFIED SCAFFOLD: PARSE-checked reasoning only, never run on Windows. The
    -- Winsock struct layouts (addrinfo, fd_set) and the non-blocking connect/select
    -- dance are the riskiest points -- flagged inline with "RISK:".
-- END --

local host = require("hs.foundation")
local ffi  = host.ffi
local bit  = host.bit

-- Winsock FFI (all unique to this module) --
    local WS = ffi.load("ws2_32")

    ffi.cdef[[
typedef uintptr_t SOCKET;

typedef struct addrinfo {
  int    ai_flags; int ai_family; int ai_socktype; int ai_protocol;
  size_t ai_addrlen; char* ai_canonname; void* ai_addr; struct addrinfo* ai_next;
} addrinfo;

typedef struct { unsigned int fd_count; SOCKET fd_array[64]; } ws_fd_set;
typedef struct { long tv_sec; long tv_usec; } ws_timeval;

int    WSAStartup(unsigned short, void*);
int    WSACleanup(void);
int    WSAGetLastError(void);
SOCKET socket(int, int, int);
int    connect(SOCKET, const void*, int);
int    send(SOCKET, const char*, int, int);
int    recv(SOCKET, char*, int, int);
int    closesocket(SOCKET);
int    ioctlsocket(SOCKET, long, unsigned long*);
int    getaddrinfo(const char*, const char*, const addrinfo*, addrinfo**);
void   freeaddrinfo(addrinfo*);
int    select(int, ws_fd_set*, ws_fd_set*, ws_fd_set*, const ws_timeval*);
]]
-- END --

-- Constants --
    local AF_INET        = 2
    local SOCK_STREAM    = 1
    local IPPROTO_TCP    = 6
    local FIONBIO        = 0x8004667E   -- ioctlsocket: toggle non-blocking mode
    local WSAEWOULDBLOCK = 10035
    local SOCKET_ERROR   = -1
    local INVALID_SOCKET = ffi.cast("SOCKET", ffi.cast("intptr_t", -1))

    local POLL_MS        = 20           -- how often the runloop services the socket
    local RECV_CHUNK     = 16384

    -- WebSocket opcodes.
    local OP_CONT  = 0x0
    local OP_TEXT  = 0x1
    local OP_BIN   = 0x2
    local OP_CLOSE = 0x8
    local OP_PING  = 0x9
    local OP_PONG  = 0xA

    local IS_WINDOWS = package.config:sub(1, 1) == "\\"
-- END --

-- WSAStartup (once for the process) --
    -- ws2_32 must be initialised before any socket call. Version 2.2 (0x0202). WSADATA
    -- is ~400 bytes; a generous fixed buffer receives it (we never read the fields).
    local wsaReady = false
    local function ensureWSA()
        if wsaReady then return true end
        if not IS_WINDOWS then
            io.stderr:write("[hs.websocket] only implemented on Windows\n")
            return false
        end
        local wsadata = ffi.new("char[?]", 512)
        if WS.WSAStartup(0x0202, wsadata) ~= 0 then
            io.stderr:write("hs.websocket: WSAStartup failed\n")
            return false
        end
        wsaReady = true
        return true
    end
-- END --

-- URL parsing --
    -- ws://host[:port]/path  ->  scheme, host, port, path. wss is recognised so we can
    -- reject it with a clear message rather than silently mis-parsing.
    local function parseUrl(url)
        local scheme, rest = url:match("^(%a+)://(.*)$")
        if not scheme then return nil end
        scheme = scheme:lower()
        local hostport, path = rest:match("^([^/]+)(/.*)$")
        if not hostport then hostport, path = rest, "/" end
        local h, p = hostport:match("^([^:]+):(%d+)$")
        if not h then h = hostport; p = (scheme == "wss") and 443 or 80 end
        return { scheme = scheme, host = h, port = tonumber(p), path = path }
    end
-- END --

-- Base64 (for the Sec-WebSocket-Key) --
    local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local function base64(data)
        local out = {}
        for i = 1, #data, 3 do
            local a, b, c = data:byte(i, i + 2)
            local n = bit.lshift(a, 16) + bit.lshift(b or 0, 8) + (c or 0)
            local c1 = bit.band(bit.rshift(n, 18), 0x3F)
            local c2 = bit.band(bit.rshift(n, 12), 0x3F)
            local c3 = bit.band(bit.rshift(n, 6), 0x3F)
            local c4 = bit.band(n, 0x3F)
            out[#out + 1] = B64:sub(c1 + 1, c1 + 1)
            out[#out + 1] = B64:sub(c2 + 1, c2 + 1)
            out[#out + 1] = b and B64:sub(c3 + 1, c3 + 1) or "="
            out[#out + 1] = c and B64:sub(c4 + 1, c4 + 1) or "="
        end
        return table.concat(out)
    end

    local function randomKey()
        local b = {}
        for i = 1, 16 do b[i] = string.char(math.random(0, 255)) end
        return base64(table.concat(b))
    end
-- END --

-- Frame encode (client -> server; all client frames MUST be masked, RFC 6455 5.3) --
    local function encodeFrame(opcode, payload)
        payload = payload or ""
        local len = #payload
        local out = { string.char(0x80 + opcode) }   -- FIN=1 + opcode
        if len < 126 then
            out[#out + 1] = string.char(0x80 + len)   -- MASK=1 + 7-bit len
        elseif len < 65536 then
            out[#out + 1] = string.char(0x80 + 126,
                bit.band(bit.rshift(len, 8), 0xFF), bit.band(len, 0xFF))
        else
            out[#out + 1] = string.char(0x80 + 127, 0, 0, 0, 0,
                bit.band(bit.rshift(len, 24), 0xFF), bit.band(bit.rshift(len, 16), 0xFF),
                bit.band(bit.rshift(len, 8), 0xFF), bit.band(len, 0xFF))
        end
        local m = { math.random(0, 255), math.random(0, 255),
                    math.random(0, 255), math.random(0, 255) }
        out[#out + 1] = string.char(m[1], m[2], m[3], m[4])
        local masked = {}
        for i = 1, len do
            masked[i] = string.char(bit.bxor(payload:byte(i), m[((i - 1) % 4) + 1]))
        end
        out[#out + 1] = table.concat(masked)
        return table.concat(out)
    end
-- END --

-- Frame decode (server -> client; unmasked). Pulls every COMPLETE frame out of buf,
-- calls onFrame(fin, opcode, payload) for each, and returns the unconsumed tail. --
    local function decodeFrames(buf, onFrame)
        local pos = 1
        local n = #buf
        while true do
            if n - pos + 1 < 2 then break end
            local b1, b2 = buf:byte(pos), buf:byte(pos + 1)
            local fin    = bit.band(b1, 0x80) ~= 0
            local opcode = bit.band(b1, 0x0F)
            local masked = bit.band(b2, 0x80) ~= 0
            local len    = bit.band(b2, 0x7F)
            local hdr    = 2
            if len == 126 then
                if n - pos + 1 < 4 then break end
                len = bit.bor(bit.lshift(buf:byte(pos + 2), 8), buf:byte(pos + 3))
                hdr = 4
            elseif len == 127 then
                if n - pos + 1 < 10 then break end
                -- Low 32 bits only (pos+6..pos+9); a single WS message never approaches
                -- 4 GiB in this port. RISK: a peer sending a >4GiB frame is unsupported.
                len = 0
                for i = pos + 6, pos + 9 do len = len * 256 + buf:byte(i) end
                hdr = 10
            end
            local mkey
            if masked then
                if n - pos + 1 < hdr + 4 then break end
                mkey = { buf:byte(pos + hdr, pos + hdr + 3) }
                hdr = hdr + 4
            end
            if n - pos + 1 < hdr + len then break end   -- frame not fully arrived yet
            local payload = buf:sub(pos + hdr, pos + hdr + len - 1)
            if mkey then
                local t = {}
                for i = 1, len do
                    t[i] = string.char(bit.bxor(payload:byte(i), mkey[((i - 1) % 4) + 1]))
                end
                payload = table.concat(t)
            end
            onFrame(fin, opcode, payload)
            pos = pos + hdr + len
        end
        return buf:sub(pos)
    end
-- END --

-- fd_set helper: a set holding just our socket (for the connect-completion select). --
    local function oneFdSet(sock)
        local s = ffi.new("ws_fd_set")
        s.fd_count = 1
        s.fd_array[0] = sock
        return s
    end

    local function fdIsSet(set, sock)
        for i = 0, tonumber(set.fd_count) - 1 do
            if set.fd_array[i] == sock then return true end
        end
        return false
    end
-- END --

local websocket = {}

-- The websocket object --
    local WSObj = {}
    WSObj.__index = WSObj

    -- Fire the user callback, guarded (a throw must never unwind the runloop tick).
    local function emit(self, event, message)
        if not self._cb then return end
        local ok, err = pcall(self._cb, event, message)
        if not ok then
            io.stderr:write("hs.websocket callback error: " .. tostring(err) .. "\n")
        end
    end

    -- Push raw bytes to the socket. Best-effort: on a non-blocking short write we log
    -- and drop the tail (mudscript's messages are small and fit one send). RISK: a
    -- congested socket could truncate a large frame; a proper client would queue.
    local function rawSend(self, bytes)
        if self._sock == INVALID_SOCKET then return end
        local n = WS.send(self._sock, bytes, #bytes, 0)
        if n == SOCKET_ERROR then
            local e = WS.WSAGetLastError()
            if e ~= WSAEWOULDBLOCK then self:_fail("send failed (" .. e .. ")") end
        end
    end

    -- Tear down the socket + poll tick exactly once, emitting `event` (unless already
    -- torn down). Used by both the clean close path and the failure path.
    local function teardown(self, event, message)
        if self._closed then return end
        self._closed = true
        if self._handle then self._handle:cancel(); self._handle = nil end
        if self._sock ~= INVALID_SOCKET then
            WS.closesocket(self._sock)
            self._sock = INVALID_SOCKET
        end
        emit(self, event, message)
    end

    function WSObj:_fail(message)
        teardown(self, "fail", message)
    end

    -- Send the HTTP/1.1 Upgrade request. Called once, when the socket becomes writable.
    local function sendHandshake(self)
        local u = self._url
        local hostHdr = u.host .. ((u.port ~= 80) and (":" .. u.port) or "")
        local req = table.concat({
            "GET " .. u.path .. " HTTP/1.1",
            "Host: " .. hostHdr,
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: " .. self._key,
            "Sec-WebSocket-Version: 13",
            "", "",
        }, "\r\n")
        rawSend(self, req)
        self._phase = "handshake"
    end

    -- Dispatch one decoded frame. Handles control frames (ping/pong/close) inline and
    -- reassembles fragmented data frames into a whole "received" message.
    local function handleFrame(self, fin, opcode, payload)
        if opcode == OP_CLOSE then
            -- Echo a close and shut down cleanly.
            rawSend(self, encodeFrame(OP_CLOSE, ""))
            teardown(self, "closed", payload)
        elseif opcode == OP_PING then
            rawSend(self, encodeFrame(OP_PONG, payload))
        elseif opcode == OP_PONG then
            emit(self, "pong", payload)
        elseif opcode == OP_TEXT or opcode == OP_BIN or opcode == OP_CONT then
            self._msg = (self._msg or "") .. payload
            if fin then
                local m = self._msg
                self._msg = nil
                emit(self, "received", m)
            end
        end
    end

    -- Non-blocking recv of whatever is available; returns the bytes ("" if none),
    -- or nil if the peer closed / the socket errored (caller tears down).
    local function drainSocket(self)
        local acc = {}
        while true do
            local n = WS.recv(self._sock, self._rbuf, RECV_CHUNK, 0)
            if n > 0 then
                acc[#acc + 1] = ffi.string(self._rbuf, n)
                if n < RECV_CHUNK then break end   -- drained for now
            elseif n == 0 then
                return table.concat(acc), true      -- graceful peer close
            else
                local e = WS.WSAGetLastError()
                if e == WSAEWOULDBLOCK then break end
                self:_fail("recv failed (" .. e .. ")")
                return nil
            end
        end
        return table.concat(acc), false
    end

    -- The single per-socket runloop tick: advance connect -> handshake -> open, then
    -- pump frames. Scheduled repeating every POLL_MS; cancelled on teardown.
    local function poll(self)
        if self._closed then return end

        if self._phase == "connecting" then
            -- RISK: non-blocking connect signals completion by the socket becoming
            -- writable; failure by it landing in the exception set. select() with a
            -- zero timeout probes both without blocking the runloop.
            local wr = oneFdSet(self._sock)
            local ex = oneFdSet(self._sock)
            local tv = ffi.new("ws_timeval"); tv.tv_sec = 0; tv.tv_usec = 0
            local r = WS.select(0, nil, wr, ex, tv)
            if r > 0 then
                if fdIsSet(ex, self._sock) then
                    self:_fail("connect failed"); return
                elseif fdIsSet(wr, self._sock) then
                    sendHandshake(self)
                end
            end
            return
        end

        local data, peerClosed = drainSocket(self)
        if data == nil then return end   -- _fail already fired

        if self._phase == "handshake" then
            self._hsbuf = (self._hsbuf or "") .. data
            local head = self._hsbuf:find("\r\n\r\n", 1, true)
            if head then
                local headers = self._hsbuf:sub(1, head - 1)
                if not headers:match("^HTTP/1%.1 101") then
                    self:_fail("handshake rejected: " .. (headers:match("^[^\r\n]*") or "?"))
                    return
                end
                -- Bytes after the header terminator are the first WS frame bytes.
                self._fbuf  = self._hsbuf:sub(head + 4)
                self._hsbuf = nil
                self._phase = "open"
                emit(self, "open")
                -- Flush anything queued via :send() before we were open.
                local q = self._sendq; self._sendq = nil
                if q then for _, m in ipairs(q) do rawSend(self, encodeFrame(OP_TEXT, m)) end end
            end
        elseif self._phase == "open" then
            if data ~= "" then
                self._fbuf = decodeFrames(self._fbuf .. data, function(fin, op, pl)
                    handleFrame(self, fin, op, pl)
                end)
            end
        end

        if peerClosed and not self._closed then
            teardown(self, "closed", "")
        end
    end

    -- :send(message) -> self. Sends a text frame; queues if the handshake is not yet
    -- complete (flushed on "open"). No-op after close.
    function WSObj:send(message)
        message = tostring(message or "")
        if self._closed then return self end
        if self._phase == "open" then
            rawSend(self, encodeFrame(OP_TEXT, message))
        else
            self._sendq = self._sendq or {}
            self._sendq[#self._sendq + 1] = message
        end
        return self
    end

    -- :close() -> self. Sends a close frame (best effort) and tears down. Idempotent.
    function WSObj:close()
        if not self._closed then
            if self._phase == "open" then rawSend(self, encodeFrame(OP_CLOSE, "")) end
            teardown(self, "closed", "")
        end
        return self
    end

    function WSObj:status()
        return self._closed and "closed" or self._phase
    end
-- END --

-- hs.websocket.new(url, callback) -> ws --
    -- Resolves the host, opens a non-blocking socket, starts a non-blocking connect,
    -- and schedules the poll tick. Returns synchronously; the "open"/"fail" callback
    -- arrives on a later runloop tick. wss:// and bad URLs fail asynchronously so the
    -- caller always learns via the callback, never via a raised error here.
    function websocket.new(url, callback)
        local self = setmetatable({
            _cb     = callback,
            _sock   = INVALID_SOCKET,
            _phase  = "connecting",
            _closed = false,
            _rbuf   = ffi.new("char[?]", RECV_CHUNK),
            _fbuf   = "",
        }, WSObj)

        -- Defer every failure to the first tick so the callback fires uniformly.
        local function failSoon(msg)
            self._handle = host.schedule(0, function() self:_fail(msg) end)
            return self
        end

        if not ensureWSA() then return failSoon("winsock unavailable") end

        local u = parseUrl(url or "")
        if not u then return failSoon("bad url: " .. tostring(url)) end
        if u.scheme == "wss" then
            return failSoon("wss:// (TLS) is not supported by hs.websocket")
        end
        if u.scheme ~= "ws" then
            return failSoon("unsupported scheme: " .. u.scheme)
        end
        self._url = u
        self._key = randomKey()

        -- Resolve host:port to a sockaddr via getaddrinfo (IPv4 TCP).
        local hints = ffi.new("addrinfo")
        hints.ai_family   = AF_INET
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        local res = ffi.new("addrinfo*[1]")
        if WS.getaddrinfo(u.host, tostring(u.port), hints, res) ~= 0 or res[0] == nil then
            return failSoon("cannot resolve " .. u.host)
        end
        local ai = res[0]

        local sock = WS.socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol)
        if sock == INVALID_SOCKET then
            WS.freeaddrinfo(ai)
            return failSoon("socket() failed")
        end

        -- Non-blocking BEFORE connect so connect returns immediately (WSAEWOULDBLOCK)
        -- and completion is detected by select() in poll().
        local nb = ffi.new("unsigned long[1]", 1)
        WS.ioctlsocket(sock, FIONBIO, nb)

        local rc = WS.connect(sock, ai.ai_addr, tonumber(ai.ai_addrlen))
        WS.freeaddrinfo(ai)
        if rc == SOCKET_ERROR then
            local e = WS.WSAGetLastError()
            if e ~= WSAEWOULDBLOCK then
                WS.closesocket(sock)
                return failSoon("connect() failed (" .. e .. ")")
            end
        end

        self._sock = sock
        -- Repeating tick on the ONE runloop -- no thread. Drives every subsequent stage.
        self._handle = host.schedule(POLL_MS, function() poll(self) end, POLL_MS)
        return self
    end
-- END --

return websocket
