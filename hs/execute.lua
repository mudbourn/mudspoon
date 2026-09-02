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
    local MARKER = "__hammerspoon_rc__"
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
        -- shExe() is already quoted (run_mudscript quotes the resolved path, which may
        -- live under "Program Files"). io.popen runs this via `cmd /c <str>`, and cmd
        -- strips ONE outer quote pair -- which would eat the exe's own quotes and split
        -- the path on its space. Wrap the whole line in an extra pair so cmd strips that
        -- wrapper and leaves the inner quoting intact.
        local probeCmd = shExe() .. ' -c "echo __MSH_OK__" 2>nul'
        if IS_WINDOWS then probeCmd = '"' .. probeCmd .. '"' end
        local h = io.popen(probeCmd, "r")
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

        local path = ("%s/hammerspoon_exec_%d_%d.sh")
            :format(tempDir():gsub("[/\\]+$", ""), os.time(), math.random(1, 1e9))

        local f, ferr = io.open(path, "wb")
        if not f then return nil, ferr end
        f:write(command, "\necho ", MARKER, "=$?\n")
        f:close()

        -- sh reads the script from the quoted path. shExe() is itself already quoted,
        -- so wrap the whole command in an extra outer pair: io.popen's `cmd /c` strips
        -- one pair, which must be this wrapper -- not the exe's own quotes (see the probe
        -- above for the full cmd quote-stripping rationale).
        local shCmd = shExe() .. ' "' .. path .. '"'
        if IS_WINDOWS then shCmd = '"' .. shCmd .. '"' end
        local handle = io.popen(shCmd, "r")
        if not handle then os.remove(path); return nil, "io.popen failed" end
        local out = handle:read("*a") or ""
        local ok = handle:close()
        os.remove(path)
        return out, nil, ok
    end
-- END --

-- Native file-op fast path (Windows only) --
    -- Runs the plain file operations mac/ shells out (mkdir, cp, rm, mv, a find
    -- listing) in process. Only the exact command shapes mac/ emits are matched.
    -- Anything else returns nil and takes the real shell.

    -- argvOf: split into argv, honouring POSIX single quotes and the '\'' idiom
    -- sq() produces. nil on an unbalanced quote.
    local function argvOf(command)
        local toks = {}
        local cur  = {}
        local has  = false
        local i    = 1
        local n    = #command

        while i <= n do
            local c = command:sub(i, i)

            if c == "'" then
                has = true
                local j = command:find("'", i + 1, true)
                if not j then return nil end
                cur[#cur + 1] = command:sub(i + 1, j - 1)
                i = j + 1
            elseif c == "\\" then
                has = true
                cur[#cur + 1] = command:sub(i + 1, i + 1)
                i = i + 2
            elseif c == " " or c == "\t" then
                if has then
                    toks[#toks + 1] = table.concat(cur)
                    cur = {}
                    has = false
                end
                i = i + 1
            else
                has = true
                cur[#cur + 1] = c
                i = i + 1
            end
        end

        if has then toks[#toks + 1] = table.concat(cur) end
        return toks
    end

    local function argvIsPlain(argv)
        for _, t in ipairs(argv) do
            if t:find("[|&<>;$`*?]") then return false end
        end
        return true
    end

    local function nativeMkdirP(dir)
        local fs = require("hs.fs")
        local acc = nil

        for part in dir:gsub("\\", "/"):gmatch("[^/]+") do
            acc = acc and (acc .. "/" .. part) or part
            if not (acc:match("^%a:$")) then
                pcall(function() fs.mkdir(acc) end)
            end
        end

        return true
    end

    local function nativeCopyFile(src, dest)
        local fin = io.open(src, "rb")
        if not fin then return false end

        local fout = io.open(dest, "wb")
        if not fout then
            fin:close()
            return false
        end

        while true do
            local chunk = fin:read(1024 * 256)
            if not chunk then break end
            fout:write(chunk)
        end

        fin:close()
        fout:close()
        return true
    end

    local function nativeRemoveTree(path)
        local fs = require("hs.fs")
        local attr = fs.attributes(path)
        if not attr then return true end

        if attr.mode == "directory" then
            local it, dobj = fs.dir(path)
            local names = {}
            for name in it do
                if name ~= "." and name ~= ".." then names[#names + 1] = name end
            end
            if dobj then dobj:close() end

            for _, name in ipairs(names) do
                nativeRemoveTree(path .. "/" .. name)
            end

            pcall(function() fs.rmdir(path) end)
            return true
        end

        os.remove(path)
        return true
    end

    -- nativeFind: `find . -type f` as ./rel lines, dropping .DS_Store and, when
    -- dropBak, *.bak.
    local function nativeFind(baseDir, dropBak, out, prefix)
        local fs = require("hs.fs")
        local it, dobj = fs.dir(baseDir)
        local names = {}
        for name in it do
            if name ~= "." and name ~= ".." then names[#names + 1] = name end
        end
        if dobj then dobj:close() end

        for _, name in ipairs(names) do
            local full = baseDir .. "/" .. name
            local rel  = prefix .. name
            local attr = fs.attributes(full)

            if attr and attr.mode == "directory" then
                nativeFind(full, dropBak, out, rel .. "/")
            elseif attr then
                local skip = (name == ".DS_Store") or (dropBak and name:match("%.bak$"))
                if not skip then out[#out + 1] = "./" .. rel end
            end
        end

        return out
    end

    -- nativeRun: returns (out, rc) on a matched shape, nil to fall back. rc is 0 on
    -- success, 1 on a failed op, matching the shell's exit code.
    local function nativeRun(command)
        local ok, fs = pcall(require, "hs.fs")
        if not ok or not fs then return nil end

        if command:match("^/sbin/md5 ") then return "", 127 end

        local quotedDir, mid = command:match(
            "^cd (.-) && find %. %-type f ! %-name '%.DS_Store'(.-) 2>/dev/null$")
        if quotedDir and (mid == "" or mid == " ! -name '*.bak'") then
            local argv = argvOf(quotedDir)
            if argv and argv[1] and not argv[2] then
                local dropBak = mid ~= ""
                local lines   = nativeFind(argv[1], dropBak, {}, "")
                if #lines == 0 then return "", 0 end
                return table.concat(lines, "\n") .. "\n", 0
            end
        end

        local argv = argvOf(command)
        if not argv or not argvIsPlain(argv) then return nil end
        local a1, a2, a3, a4 = argv[1], argv[2], argv[3], argv[4]

        if a1 == "mkdir" and a2 == "-p" and a3 and not a4 then
            nativeMkdirP(a3)
            return "", 0
        end

        if a1 == "/bin/cp" and a2 and a3 and not a4 then
            return "", nativeCopyFile(a2, a3) and 0 or 1
        end

        if a1 == "/bin/rm" and (a2 == "-rf" or a2 == "-f") and a3 and not a4 then
            nativeRemoveTree(a3)
            return "", 0
        end

        if a1 == "/bin/mv" and a2 and a3 and not a4 then
            if os.rename(a2, a3) then return "", 0 end
            return nil
        end

        return nil
    end
-- END --

-- execute --
    -- with_shell defaults to true (Hammerspoon default). When true we guarantee a
    -- POSIX shell + the exit-code marker; with_shell=false runs the raw string
    -- through the platform's own popen shell (cmd.exe on Windows) with no marker,
    -- the documented escape hatch for callers that want the native shell verbatim.
    local function execute(command, with_shell)
        if with_shell == nil then with_shell = true end

        if with_shell and IS_WINDOWS then
            local out, rc = nativeRun(command)
            if out ~= nil then
                return out, (rc == 0) or nil, "exit", rc
            end
        end

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
