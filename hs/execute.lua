-- hs.execute  (leaf) --
    -- Hammerspoon's hs.execute is a FUNCTION, not a table:
    --   hs.execute(command [, with_shell]) -> output, status, type, rc
    -- so this module returns the callable directly. `require("hs.execute")`
    -- yields a function you invoke as hs.execute(cmd).
    --
    -- Leaf: no Foundation, no FFI. Pure io.popen / os.execute.
    --
    -- SHELL PORTABILITY: mudscript's mac/ builds UNIX command strings (`/bin/cp`,
    -- `mkdir -p`, `shasum -a 256`, `command -v`, single-quote `sq()` quoting,
    -- `2>/dev/null`) that cmd.exe cannot run. On Windows we do NOT translate them --
    -- we route the string through a real POSIX shell (`sh -c`, run as `sh <file>`;
    -- see below), so the strings execute exactly as written on mac. The rig must
    -- provide that `sh` (busybox-w64 or git-bash) plus the tools the strings call
    -- (shasum/base64/jq); point at it with $MUDSPOON_SH (default: `sh` on PATH).
    -- On mac/unix io.popen's shell already IS a POSIX shell, so we run directly.
-- END --

-- Platform + shell resolution --
    -- LuaJIT: package.config's first char is the path separator -- `\` only on
    -- Windows. Reliable and needs no FFI, so this leaf stays Foundation-free.
    local IS_WINDOWS = package.config:sub(1, 1) == "\\"

    -- The POSIX shell to route through on Windows. Override with $MUDSPOON_SH to a
    -- full path (e.g. C:/mudspoon/bin/busybox.exe sh, or a git-bash sh.exe). A bare
    -- `sh` relies on PATH. Only consulted on Windows.
    local function shExe()
        return os.getenv("MUDSPOON_SH") or "sh"
    end

    -- A writable temp dir. run_mudscript shims TMPDIR; TEMP/TMP are the native vars.
    local function tempDir()
        return os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "."
    end
-- END --

-- Status derivation --
    -- LuaJIT is Lua 5.1: io.popen's handle:close() returns just true/nil, NOT the
    -- Lua 5.2+ (status, type, rc) triple Hammerspoon relays. So io.popen alone
    -- can capture stdout but cannot recover the real exit code.
    --
    -- To honor the 4-tuple contract we append a marker that echoes the shell's exit
    -- status on its own final line, then strip that line back off the returned
    -- output. Because every shelled command now runs under a POSIX sh (directly on
    -- mac, via `sh <file>` on Windows), the POSIX `$?` form is all we need.
    local MARKER = "__mudspoon_rc__"
-- END --

-- One-time sh availability probe (Windows) --
    -- Without a probe, every file op mac/ runs would spawn cmd.exe only for it to
    -- print "'sh' is not recognized" -- 20+ lines of console spam per boot. Instead
    -- check once (stderr suppressed via `2>nul` so the probe itself is silent), cache
    -- the verdict, and warn exactly once with how to fix it. When sh is missing,
    -- shelled calls no-op cleanly (guardian hashing / file ops just don't run).
    local shState  -- nil = unknown, then true/false
    local function shAvailable()
        if shState ~= nil then return shState end
        local h = io.popen(shExe() .. ' -c "echo __MSH_OK__" 2>nul', "r")
        local probe = h and h:read("*a") or ""
        if h then h:close() end
        shState = probe:find("__MSH_OK__", 1, true) ~= nil
        if not shState then
            io.stderr:write("[hs.execute] no POSIX shell found (MUDSPOON_SH=" .. shExe()
                .. "). mac/ file ops + guardian hashing will no-op until one exists. "
                .. "Install git-for-Windows or busybox-w64, or set MUDSPOON_SH to an sh.exe.\n")
        end
        return shState
    end
-- END --

-- Windows: run the command as a script under a real POSIX shell --
    -- Writing the command to a temp file and running `sh <file>` keeps the cmd.exe
    -- command line free of every character cmd mangles (" & | < > %) -- only a plain
    -- file path reaches it. The script itself is pure sh, so mac/'s single-quote
    -- quoting and `2>/dev/null` redirects run verbatim. Written binary ("wb") so
    -- line endings stay bare \n; busybox sh chokes on \r.
    local function runViaSh(command)
        if not shAvailable() then return nil, "no sh" end

        local path = ("%s/mudspoon_exec_%d_%d.sh")
            :format(tempDir():gsub("[/\\]+$", ""), os.time(), math.random(1, 1e9))

        local f, ferr = io.open(path, "wb")
        if not f then return nil, ferr end
        f:write(command, "\necho ", MARKER, "=$?\n")
        f:close()

        -- Quote the (space-free-safe) path for cmd; sh reads the script from it.
        local handle = io.popen(shExe() .. ' "' .. path .. '"', "r")
        if not handle then os.remove(path); return nil, "io.popen failed" end
        local out = handle:read("*a") or ""
        local ok = handle:close()
        os.remove(path)
        return out, nil, ok
    end
-- END --

-- execute --
    -- with_shell defaults to true (Hammerspoon default). When true we guarantee a
    -- POSIX shell + the exit-code marker; with_shell=false runs the raw string
    -- through the platform's own popen shell (cmd.exe on Windows) with no marker,
    -- the documented escape hatch for callers that want the native shell verbatim.
    local function execute(command, with_shell)
        if with_shell == nil then with_shell = true end

        local out, ok

        if with_shell and IS_WINDOWS then
            -- Route through the bundled POSIX sh via a temp script.
            local rout, rerr, rok = runViaSh(command)
            if rout == nil then return "", nil, "exit", -1 end
            out, ok = rout, rok
        else
            -- mac/unix (popen shell is already POSIX), or with_shell=false raw run.
            local toRun = command
            if with_shell then
                toRun = command .. " ; echo " .. MARKER .. "=$?"
            end
            local handle = io.popen(toRun, "r")
            if not handle then return "", nil, "exit", -1 end
            out = handle:read("*a") or ""
            ok  = handle:close()   -- Lua 5.1: true/nil only
        end

        local status, typ, rc

        -- Prefer the marker's rc when we injected it and can parse one out.
        if with_shell then
            local code
            for line in out:gmatch("[^\r\n]+") do
                local m = line:match("^" .. MARKER .. "=(%-?%d+)$")
                if m then code = tonumber(m) end  -- last valid marker wins
            end
            -- Strip the marker line from the returned output.
            out = out:gsub(MARKER .. "=[^\r\n]*\r?\n?", "")
            if code then
                rc     = code
                typ    = "exit"
                status = (code == 0) or nil  -- Hammerspoon: true on 0, else nil
            end
        end

        -- Fallback: no parseable marker (with_shell=false, or an odd shell).
        if status == nil and rc == nil then
            typ    = "exit"
            status = ok and true or nil
            rc     = ok and 0 or 1
        end

        return out, status, typ, rc
    end
-- END --

return execute
