-- hs.shims --
    -- Windows stand-ins for the macOS commands mudscript shells out to.
    -- open(argv) plays /usr/bin/open and zipCommand(command) rewrites a
    -- /usr/bin/zip invocation to the bsdtar that ships with Windows.
-- END --

local ffi = require("ffi")

local shims = {}

-- Platform --
    local IS_WINDOWS = package.config:sub(1, 1) == "\\"
-- END --

-- Win32 --
    local shell32
    local kernel32

    if IS_WINDOWS then
        pcall(ffi.cdef, [[
void* ShellExecuteW(void*, const unsigned short*, const unsigned short*, const unsigned short*, const unsigned short*, int);
int MultiByteToWideChar(unsigned int, unsigned long, const char*, int, unsigned short*, int);
]])

        local okShell, shellLib = pcall(ffi.load, "shell32")
        local okKernel, kernelLib = pcall(ffi.load, "kernel32")

        shell32 = okShell and shellLib or nil
        kernel32 = okKernel and kernelLib or nil
    end

    local CP_UTF8 = 65001
    local SW_SHOWNORMAL = 1

    -- A NUL terminated UTF-16 buffer for a UTF-8 string
    local function wide(str)
        if not str then return nil end

        local n = kernel32.MultiByteToWideChar(CP_UTF8, 0, str, -1, nil, 0)
        local buf = ffi.new("unsigned short[?]", n + 1)

        kernel32.MultiByteToWideChar(CP_UTF8, 0, str, -1, buf, n)

        return buf
    end
-- END --

-- Argument parsing --
    -- Splits a POSIX word list that uses only single quotes and plain words
    local function words(text)
        local toks = {}
        local cur = {}
        local has = false
        local i = 1
        local n = #text

        while i <= n do
            local c = text:sub(i, i)

            if c == "'" then
                has = true

                local j = text:find("'", i + 1, true)
                if not j then return nil end

                cur[#cur + 1] = text:sub(i + 1, j - 1)
                i = j + 1
            elseif c == "\\" then
                has = true
                cur[#cur + 1] = text:sub(i + 1, i + 1)
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

    local function shQuote(str)
        return "'" .. str:gsub("'", "'\\''") .. "'"
    end

    local function hasShellSyntax(text)
        return text:find("[|&;<>$`*?]") ~= nil
    end

    shims.words = words
-- END --

-- open --
    local EDITOR_NAMES = {
        ["textedit"] = "notepad",
        ["text edit"] = "notepad",
        ["notepad"] = "notepad",
        ["visual studio code"] = "code",
        ["vscode"] = "code",
        ["code"] = "code",
        ["sublime text"] = "sublime",
        ["sublime"] = "sublime",
        ["zed"] = "zed",
    }

    -- An installed editor's exe path, or nil
    local function editorExe(kind)
        if kind == "notepad" then
            return "notepad.exe"
        end

        local local_ = os.getenv("LOCALAPPDATA") or ""
        local pf = os.getenv("ProgramFiles") or "C:\\Program Files"
        local candidates = {}

        if kind == "code" then
            candidates = {
                local_ .. "\\Programs\\Microsoft VS Code\\Code.exe",
                pf .. "\\Microsoft VS Code\\Code.exe",
            }
        elseif kind == "sublime" then
            candidates = {
                pf .. "\\Sublime Text\\sublime_text.exe",
                pf .. "\\Sublime Text 3\\sublime_text.exe",
            }
        elseif kind == "zed" then
            candidates = {
                local_ .. "\\Programs\\Zed\\Zed.exe",
            }
        end

        for _, path in ipairs(candidates) do
            local f = io.open(path, "rb")
            if f then
                f:close()
                return path
            end
        end

        return nil
    end

    local function isUrl(target)
        return target:match("^%a[%w+.-]*://") ~= nil or target:match("^mailto:") ~= nil
    end

    -- A target as Windows wants it: URLs untouched, paths with backslashes
    local function winTarget(target)
        if isUrl(target) then return target end

        return (target:gsub("/", "\\"))
    end

    local function quoteWin(str)
        return '"' .. str .. '"'
    end

    -- Turns open's argv (without the command word) into a launch plan or nil
    function shims.openPlan(argv)
        local app
        local asText = false
        local reveal = false
        local targets = {}
        local i = 1

        while i <= #argv do
            local a = argv[i]

            if a == "-a" then
                app = argv[i + 1]
                i = i + 2
            elseif a == "-t" then
                asText = true
                i = i + 1
            elseif a == "-R" then
                reveal = true
                i = i + 1
            elseif a == "--args" then
                break
            elseif a:sub(1, 1) == "-" and #a > 1 then
                i = i + 1
            else
                targets[#targets + 1] = winTarget(a)
                i = i + 1
            end
        end

        local target = targets[1]

        if reveal then
            if not target then return nil end

            return {
                file = "explorer.exe",
                params = "/select," .. quoteWin(target),
            }
        end

        if asText and not app then
            if not target then return nil end

            return {
                file = "notepad.exe",
                params = quoteWin(target),
            }
        end

        if app then
            local kind = EDITOR_NAMES[app:lower():gsub("%.app$", "")]
            local exe = kind and editorExe(kind)

            if not exe and app:lower():match("%.exe$") then
                exe = winTarget(app)
            end

            if exe then
                return {
                    file = exe,
                    params = target and quoteWin(target) or nil,
                }
            end

            if not target then
                return {
                    file = app,
                }
            end
        end

        if not target then return nil end

        return {
            file = target,
        }
    end

    -- Launches a plan. 0 on success and 1 on failure, like a shell exit code
    function shims.launch(plan)
        if not plan or not shell32 then return 1 end

        local rc = shell32.ShellExecuteW(
            nil,
            wide("open"),
            wide(plan.file),
            wide(plan.params),
            nil,
            SW_SHOWNORMAL
        )

        return tonumber(ffi.cast("intptr_t", rc)) > 32 and 0 or 1
    end

    function shims.open(argv)
        return shims.launch(shims.openPlan(argv))
    end

    -- The argv after the command word when a command line is open or /usr/bin/open
    function shims.openArgv(command)
        local rest = command:match("^%s*/usr/bin/open%f[%s%z](.*)$")
            or command:match("^%s*open%f[%s%z](.*)$")

        if not rest or hasShellSyntax(rest) then return nil end

        return words(rest)
    end
-- END --

-- zip --
    local function tarExe()
        local root = (os.getenv("SystemRoot") or "C:\\Windows"):gsub("\\", "/")

        return root .. "/System32/tar.exe"
    end

    -- The output name and the item names, skipping zip flags
    local function splitZipArgs(argv)
        local out
        local items = {}

        for _, a in ipairs(argv) do
            if out then
                items[#items + 1] = a
            elseif a:sub(1, 1) ~= "-" then
                out = a
            end
        end

        return out, items
    end

    -- The entries directly inside a directory, sorted
    local function listDir(dir)
        local ok, fs = pcall(require, "hs.fs")
        if not ok or not fs then return nil end

        local names = {}

        for name in fs.dir(dir) do
            if name ~= "." and name ~= ".." then names[#names + 1] = name end
        end

        table.sort(names)

        return names
    end

    -- Rewrites "cd D && /usr/bin/zip -r ... OUT ITEMS" to a bsdtar zip write
    function shims.zipCommand(command)
        local prefix, rest = command:match("^(.-)/usr/bin/zip%s+(.*)$")
        if not prefix then return nil end

        local redirect = rest:match("%s+(2>/dev/null)%s*$")

        rest = rest:gsub("%s+2>/dev/null%s*$", "")

        if hasShellSyntax(rest) then return nil end

        local argv = words(rest)
        if not argv then return nil end

        local out, items = splitZipArgs(argv)

        if not out or #items == 0 then return nil end

        if #items == 1 and items[1] == "." then
            local dirText = prefix:match("^%s*cd%s+(.-)%s+&&%s*$")
            local dirArgv = dirText and words(dirText)
            local names = dirArgv and dirArgv[1] and not dirArgv[2] and listDir(dirArgv[1])

            if not names or #names == 0 then return nil end

            items = names
        end

        local parts = {
            shQuote(tarExe()),
            "-a",
            "-c",
            "-f",
            shQuote(out),
            "--",
        }

        for _, item in ipairs(items) do parts[#parts + 1] = shQuote(item) end

        if redirect then parts[#parts + 1] = redirect end

        return prefix .. table.concat(parts, " ")
    end

    -- Rewrites "/usr/bin/unzip -Z1 ARCHIVE" to a bsdtar listing
    function shims.unzipListCommand(command)
        local rest = command:match("^%s*/usr/bin/unzip%s+%-Z1%s+(.*)$")
        if not rest then return nil end

        local redirect = rest:match("%s+(2>/dev/null)%s*$")

        rest = rest:gsub("%s+2>/dev/null%s*$", "")

        if hasShellSyntax(rest) then return nil end

        local argv = words(rest)
        if not argv or #argv ~= 1 then return nil end

        local parts = {
            shQuote(tarExe()),
            "-t",
            "-f",
            shQuote(argv[1]),
        }

        if redirect then parts[#parts + 1] = redirect end

        return table.concat(parts, " ")
    end

    -- The tar argv for a zip task, or nil when the path is not zip
    function shims.zipTaskArgs(args)
        local out, items = splitZipArgs(args)

        if not out or #items == 0 then return nil end

        local result = { "-a", "-c", "-f", out, "--" }

        for _, item in ipairs(items) do result[#result + 1] = item end

        return tarExe(), result
    end
-- END --

-- Admin flag tree --
    local MAC_ADMIN_BASE = "/Library/Application Support/mudscript"

    local TRUSTED_SIDS = {
        ["S-1-5-18"] = true,
        ["S-1-5-32-544"] = true,
        ["S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"] = true,
    }

    local WRITE_MASK = 0x50000000 + 0xD0000 + 0x156

    local INHERIT_ONLY_ACE = 0x08

    local FILE_ATTRIBUTE_DIRECTORY = 0x10

    local INVALID_ATTRIBUTES = 0xFFFFFFFF

    local SE_FILE_OBJECT = 1

    local OWNER_AND_DACL = 0x5

    local advapi32

    if IS_WINDOWS then
        local decls = {
            "unsigned long GetNamedSecurityInfoW(const unsigned short*, int, unsigned long, void**, void**, void**, void**, void**);",
            "int GetAce(void*, unsigned long, void**);",
            "int ConvertSidToStringSidA(void*, char**);",
            "void* LocalFree(void*);",
            "unsigned long GetFileAttributesW(const unsigned short*);",
        }

        for _, decl in ipairs(decls) do pcall(ffi.cdef, decl) end

        local okAdv, advLib = pcall(ffi.load, "advapi32")

        advapi32 = okAdv and advLib or nil
    end

    -- The Windows path for a path under the mac admin base, or nil
    function shims.adminPath(path)
        if path:sub(1, #MAC_ADMIN_BASE) ~= MAC_ADMIN_BASE then return nil end

        local rest = path:sub(#MAC_ADMIN_BASE + 1)

        if rest ~= "" and rest:sub(1, 1) ~= "/" then return nil end

        local root = (os.getenv("ProgramData") or "C:\\ProgramData") .. "\\mudscript"

        return root .. rest:gsub("/", "\\")
    end

    local function sidString(sid)
        local out = ffi.new("char*[1]")

        if kernel32 == nil or advapi32.ConvertSidToStringSidA(sid, out) == 0 then return nil end

        local str = ffi.string(out[0])

        kernel32.LocalFree(out[0])

        return str
    end

    -- True when only SYSTEM, Administrators and TrustedInstaller own or can write the path
    local function adminOnly(winPath)
        local owner = ffi.new("void*[1]")
        local dacl = ffi.new("void*[1]")
        local sd = ffi.new("void*[1]")

        local rc = advapi32.GetNamedSecurityInfoW(wide(winPath), SE_FILE_OBJECT,
            OWNER_AND_DACL, owner, nil, dacl, nil, sd)

        if rc ~= 0 then return false end

        local ok = dacl[0] ~= nil and TRUSTED_SIDS[sidString(owner[0]) or ""] == true

        if ok then
            local count = ffi.cast("unsigned short*", dacl[0])[2]
            local ace = ffi.new("void*[1]")

            for i = 0, count - 1 do
                if advapi32.GetAce(dacl[0], i, ace) == 0 then
                    ok = false
                    break
                end

                local header = ffi.cast("unsigned char*", ace[0])
                local mask = ffi.cast("unsigned long*", header + 4)[0]
                local inheritOnly = (header[1] & INHERIT_ONLY_ACE) ~= 0
                local writes = (mask & WRITE_MASK) ~= 0

                if header[0] == 0 and not inheritOnly and writes
                    and not TRUSTED_SIDS[sidString(header + 8) or ""] then
                    ok = false
                    break
                end
            end
        end

        kernel32.LocalFree(sd[0])

        return ok
    end

    -- The stat line for one path as "%u %Lp %HT" prints it, or nil when missing
    local function statLine(winPath)
        local attr = kernel32.GetFileAttributesW(wide(winPath))

        if attr == INVALID_ATTRIBUTES then return nil end

        local isDir = (attr & FILE_ATTRIBUTE_DIRECTORY) ~= 0
        local kind = isDir and "Directory" or "Regular File"

        if not adminOnly(winPath) then return "501 777 " .. kind end

        return (isDir and "0 755 " or "0 644 ") .. kind
    end

    -- Output and rc for a stat of admin tree paths, or nil for any other command
    function shims.statCommand(command)
        local rest = command:match("^/usr/bin/stat %-f '%%u %%Lp %%HT' (.-) 2>/dev/null$")

        if not rest or not advapi32 or not kernel32 or hasShellSyntax(rest) then return nil end

        local paths = words(rest)

        if not paths or #paths == 0 then return nil end

        local lines = {}
        local rc = 0

        for _, path in ipairs(paths) do
            local winPath = shims.adminPath(path)

            if not winPath then return nil end

            local line = statLine(winPath)

            if line then
                lines[#lines + 1] = line
            else
                rc = 1
            end
        end

        if #lines == 0 then return "", rc end

        return table.concat(lines, "\n") .. "\n", rc
    end
-- END --

-- Admin elevation --
    local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    local function base64(bytes)
        local out = {}

        for i = 1, #bytes, 3 do
            local a, b, c = bytes:byte(i, i + 2)
            local n = a * 65536 + (b or 0) * 256 + (c or 0)

            for k = 3, 0, -1 do
                local idx = math.floor(n / 64 ^ k) % 64

                out[#out + 1] = B64:sub(idx + 1, idx + 1)
            end

            if not b then
                out[#out] = "="
                out[#out - 1] = "="
            elseif not c then
                out[#out] = "="
            end
        end

        return table.concat(out)
    end

    -- A powershell -EncodedCommand value for ASCII script text
    local function encodePs(lines)
        local text = table.concat(lines, "\n")

        return base64(text:gsub(".", "%0\0"))
    end

    local LOCK_LINES = {
        "$ErrorActionPreference = 'Stop'",
        "$admins = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'",
        "$system = New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'",
        "$users = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'",
        "function Lock($path, $isDir) {",
        "    if ($isDir) {",
        "        $acl = New-Object Security.AccessControl.DirectorySecurity",
        "        $inherit = 'ContainerInherit,ObjectInherit'",
        "    } else {",
        "        $acl = New-Object Security.AccessControl.FileSecurity",
        "        $inherit = 'None'",
        "    }",
        "    $acl.SetOwner($admins)",
        "    $acl.SetAccessRuleProtection($true, $false)",
        "    foreach ($sid in @($admins, $system)) {",
        "        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule $sid, 'FullControl', $inherit, 'None', 'Allow'))",
        "    }",
        "    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule $users, 'ReadAndExecute', $inherit, 'None', 'Allow'))",
        "    Set-Acl -LiteralPath $path -AclObject $acl",
        "}",
    }

    local function psQuote(str)
        return "'" .. str:gsub("'", "''") .. "'"
    end

    -- The elevated script lines that create and lock a flag file
    local function enableLines(flag)
        local lines = {}

        for _, line in ipairs(LOCK_LINES) do lines[#lines + 1] = line end

        local dir = flag:match("^(.*)\\[^\\]+$")
        local base = dir:match("^(.*)\\[^\\]+$")

        local tail = {
            "$base = " .. psQuote(base),
            "$dir = " .. psQuote(dir),
            "$flag = " .. psQuote(flag),
            "New-Item -ItemType Directory -Force -Path $dir | Out-Null",
            "Lock $base $true",
            "Lock $dir $true",
            "if (Test-Path -LiteralPath $flag) {",
            "    Remove-Item -LiteralPath $flag -Recurse -Force",
            "}",
            "New-Item -ItemType File -Path $flag | Out-Null",
            "Lock $flag $false",
            "exit 0",
        }

        for _, line in ipairs(tail) do lines[#lines + 1] = line end

        return lines
    end

    local function disableLines(flag)
        return {
            "$ErrorActionPreference = 'Stop'",
            "$flag = " .. psQuote(flag),
            "if (Test-Path -LiteralPath $flag) {",
            "    Remove-Item -LiteralPath $flag -Recurse -Force",
            "}",
            "exit 0",
        }
    end

    -- The flag file a shell command removes and then optionally recreates
    local function flagCommand(command)
        local steps = {}

        for step in (command .. " && "):gmatch("(.-) && ") do
            local argv = words(step)

            if not argv then return nil end

            steps[#steps + 1] = argv
        end

        local touched
        local removed

        for _, argv in ipairs(steps) do
            if argv[1] == "/usr/bin/touch" then touched = argv[2] end

            if argv[1] == "/bin/rm" then removed = argv[3] end
        end

        local flag = touched or removed

        if not flag or #steps ~= (touched and 7 or 1) then return nil end

        local name = flag:match("^" .. MAC_ADMIN_BASE:gsub("%p", "%%%0") .. "/devmode/([%w%._%-]+)$")

        if not name or name:match("^%.+$") then return nil end

        return shims.adminPath(flag), touched ~= nil
    end

    -- The powershell argv that runs an osascript admin shell script elevated, or nil
    function shims.adminTaskArgs(args)
        if #args ~= 2 or args[1] ~= "-e" then return nil end

        local body = args[2]:match('^do shell script "(.*)" with administrator privileges$')

        if not body then return nil end

        local flag, enable = flagCommand(body:gsub("\\(.)", "%1"))

        if not flag then return nil end

        local inner = encodePs(enable and enableLines(flag) or disableLines(flag))

        local outer = encodePs({
            "try {",
            "    $p = Start-Process powershell -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', '" .. inner .. "'",
            "    exit $p.ExitCode",
            "} catch {",
            "    exit 1",
            "}",
        })

        return "powershell.exe", {
            "-NoProfile",
            "-NonInteractive",
            "-EncodedCommand",
            outer,
        }
    end
-- END --

return shims
