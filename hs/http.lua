-- hs.http  (leaf) --
    -- The entire slice mac/ uses:
    --   hs.http.asyncGet(url, headers|nil, callback)   -- callback(code, body, resHeaders)
    -- Every mac/ call site reads (code, body, _) -- the response-headers arg is
    -- ignored -- and expects `code` to be the HTTP status number (checks `~= 200`).
    --
    -- TEXT-ONLY BY DESIGN. Per the mudspoon constraint (`hshttp-not-binary-safe`),
    -- hs.http is reserved for TEXT (GitHub JSON, the registry index); binaries are
    -- fetched with curl through hs.task so exact bytes are preserved. We implement
    -- asyncGet by shelling curl through hs.task as well: curl writes the body to a
    -- temp file (exact bytes) and prints ONLY the final HTTP status code on stdout
    -- (-w "%{http_code}"), which we parse for `code`. This keeps hs.http async
    -- (task polls off the runloop) and free of any WinHTTP/WinINet FFI surface.
    --
    -- No FFI, no Foundation typedefs -- a pure composition over hs.task. RIG-UNVERIFIED.
-- END --

local task = require("hs.task")

-- temp path (mirrors hs.task's own choice of temp dir) --
    local function tempDir()
        return (os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or ".")
            :gsub("[/\\]+$", "")
    end

    local function tmpBodyPath()
        return tempDir() .. "/mudspoon_http_"
            .. tostring(os.time()) .. "_" .. tostring(math.random(1, 1e9)) .. ".body"
    end
-- END --

local http = {}

-- asyncGet --
    -- headers: an optional {["Key"]="Value"} table (nil allowed). callback:
    -- (code, body, resHeaders). On a transport failure (curl couldn't connect /
    -- non-zero exit with no status) `code` is 0, so mac/'s `code ~= 200` guard
    -- correctly treats it as an error. resHeaders is passed as an empty table --
    -- no mac/ call site inspects it, so we don't spend a second request parsing it.
    function http.asyncGet(url, headers, callback)
        local bodyPath = tmpBodyPath()

        -- -sS: quiet but still report errors; -L: follow redirects; -o: exact bytes
        -- to disk; -w: print only the final status code on stdout.
        local args = {
            "-sS", "-L",
            "--max-time", "120",
            "-o", bodyPath,
            "-w", "%{http_code}",
        }
        if type(headers) == "table" then
            for k, v in pairs(headers) do
                args[#args + 1] = "-H"
                args[#args + 1] = tostring(k) .. ": " .. tostring(v)
            end
        end
        args[#args + 1] = url

        local t = task.new("curl", function(exitCode, stdOut, _stdErr)
            -- Read the body file (may be empty on failure), then remove it.
            local body = ""
            local f = io.open(bodyPath, "rb")
            if f then body = f:read("*a") or ""; f:close() end
            os.remove(bodyPath)

            -- The status code is the digits curl printed via -w; 0 on transport fail.
            local code = tonumber((stdOut or ""):match("%d%d%d")) or 0
            if code == 0 and exitCode == 0 then code = 0 end

            if callback then
                local ok, err = pcall(callback, code, body, {})
                if not ok then
                    io.stderr:write("hs.http.asyncGet callback error: "
                        .. tostring(err) .. "\n")
                end
            end
        end, args)

        if not t or not t:start() then
            os.remove(bodyPath)
            if callback then pcall(callback, 0, "", {}) end
            return nil
        end
        return t
    end
-- END --

return http
