local task = require("hs.task")

-- temp path (mirrors hs.task's own choice of temp dir) --
    local function tempDir()
        return (os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or ".")
            :gsub("[/\\]+$", "")
    end

    local function tmpBodyPath()
        return tempDir() .. "/hammerspoon_http_"
            .. tostring(os.time()) .. "_" .. tostring(math.random(1, 1e9)) .. ".body"
    end
-- END --

local http = {}

-- asyncGet --
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
