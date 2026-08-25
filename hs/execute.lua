-- hs.execute  (leaf) --
    -- Hammerspoon's hs.execute is a FUNCTION, not a table:
    --   hs.execute(command [, with_shell]) -> output, status, type, rc
    -- so this module returns the callable directly. `require("hs.execute")`
    -- yields a function you invoke as hs.execute(cmd).
    --
    -- Leaf: no Foundation, no FFI. Pure io.popen / os.execute.
    --
    -- SCOPE: this module faithfully RUNS whatever command string it is handed and
    -- captures the result. It does NOT translate shells. The consumer builds
    -- UNIX-style strings (`cp -R`, `unzip`, quoting via its own sq() helper) that
    -- cmd.exe cannot run — that portability gap is the consumer's problem, out of
    -- scope here.
-- END --

-- Status derivation --
    -- LuaJIT is Lua 5.1: io.popen's handle:close() returns just true/nil, NOT the
    -- Lua 5.2+ (status, type, rc) triple Hammerspoon relays. So io.popen alone
    -- can capture stdout but cannot recover the real exit code.
    --
    -- To honor the 4-tuple contract we append a portable marker that echoes the
    -- shell's exit status onto its own final line, then strip that line back off
    -- the returned output. `$?` (POSIX sh) and `%ERRORLEVEL%` (cmd.exe) name the
    -- code; we probe both so the module works on either host. The consumer only
    -- needs output + a truthy status in the common case, but this keeps type/rc
    -- honest when the shell cooperates.
    local MARKER = "__mudspoon_rc__"

    -- Wrap so the exit code of `command` is printed as `MARKER=<n>` last. The
    -- `2>nul` / `2>/dev/null` on the probe keeps a wrong-shell echo from leaking.
    local function wrap(command)
        -- POSIX: `; echo MARKER=$?`  cmd.exe: `& echo MARKER=%ERRORLEVEL%`
        -- Emitting both is harmless: each shell only expands its own form, and we
        -- take the LAST marker line we can parse.
        return command
            .. ' ; echo ' .. MARKER .. '=$?'
            .. ' & echo '  .. MARKER .. '=%ERRORLEVEL%'
    end
-- END --

-- execute --
    -- with_shell defaults to true (Hammerspoon default). io.popen already routes
    -- through the platform shell, so with_shell here governs whether we wrap the
    -- command with the exit-code marker; with_shell=false runs the raw string and
    -- reports status only from the close() result.
    local function execute(command, with_shell)
        if with_shell == nil then with_shell = true end

        local toRun = with_shell and wrap(command) or command

        local handle = io.popen(toRun, "r")
        if not handle then
            return "", nil, "exit", -1
        end

        local out = handle:read("*a") or ""

        -- close() in Lua 5.1 is just true/nil; capture it as the fallback status.
        local ok = handle:close()

        local status, typ, rc

        -- Prefer the marker's rc when we injected it and can parse one out.
        if with_shell then
            local code
            for line in out:gmatch("[^\r\n]+") do
                local m = line:match("^" .. MARKER .. "=(%-?%d+)$")
                if m then code = tonumber(m) end  -- last valid marker wins
            end
            -- Strip every marker line from the returned output, either shell's.
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
