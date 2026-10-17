-- Locate the host files and the config directory --
    local here = (arg[0] or "main.lua"):gsub("[^/\\]*$", "")
    if here == "" then here = "./" end

    local profile = os.getenv("USERPROFILE")

    local envConfig = os.getenv("MUDSPOON_CONFIG_DIR")

    if envConfig == "" then envConfig = nil end

    local hsDir = arg[1] or envConfig or ((profile or ".") .. "/.hammerspoon")

    hsDir = hsDir:gsub("[/\\]+$", "")
-- END --

-- Module search path: the repo root, compat/ and the config directory --
    package.path = table.concat({
        here  .. "?.lua",
        here  .. "?/init.lua",
        here  .. "compat/?.lua",
        hsDir .. "/?.lua",
        hsDir .. "/?/init.lua",
        package.path,
    }, ";")
-- END --

-- Capture C-level stderr (CRT abort and fastfail) to a file --
    pcall(function()
        local ffi = require("ffi")
        pcall(ffi.cdef, [[
            void* __acrt_iob_func(unsigned);
            void* freopen(const char*, const char*, void*);
            int   fputs(const char*, void*);
            int   fflush(void*);
            int   CreateDirectoryA(const char*, void*);
        ]])
        ffi.C.CreateDirectoryA(hsDir, nil)
        ffi.C.CreateDirectoryA(hsDir .. "/data", nil)

        local se = ffi.C.__acrt_iob_func(2)
        if se ~= nil and ffi.C.freopen(hsDir .. "/data/stderr.log", "a", se) ~= nil then
            ffi.C.fputs("\n===== stderr capture: boot " ..
                os.date("%Y-%m-%d %H:%M:%S") .. " (pid follows in log) =====\n", se)
            ffi.C.fflush(se)
        end
    end)
-- END --

-- Route crash dialogs to the event log instead of popups --
    pcall(function()
        local ffi = require("ffi")

        pcall(ffi.cdef, [[
            unsigned int SetErrorMode(unsigned int);
            long WerSetFlags(unsigned long);
            long WerAddExcludedApplication(const uint16_t*, int);
        ]])

        local SEM_FAILCRITICALERRORS = 0x0001

        local SEM_NOGPFAULTERRORBOX = 0x0002

        local WER_FAULT_REPORTING_NO_UI = 0x0020

        ffi.C.SetErrorMode(SEM_FAILCRITICALERRORS + SEM_NOGPFAULTERRORBOX)

        ffi.C.WerSetFlags(WER_FAULT_REPORTING_NO_UI)

        local name = "ctfmon.exe"

        local wide = ffi.new("uint16_t[?]", #name + 1)

        for i = 1, #name do wide[i - 1] = name:byte(i) end

        ffi.load("wer").WerAddExcludedApplication(wide, 0)
    end)
-- END --

-- Make os.getenv("HOME") resolve (Windows has USERPROFILE, not HOME) --
    do
        local realGetenv = os.getenv

        local shCandidates = {
            { path = here .. "bin/busybox.exe",                  busybox = true },
            { path = here .. "bin/sh.exe" },
            { path = "C:/Program Files/Git/bin/sh.exe" },
            { path = "C:/Program Files/Git/usr/bin/sh.exe" },
            { path = "C:/Program Files (x86)/Git/bin/sh.exe" },
        }
        local resolvedSh
        for _, c in ipairs(shCandidates) do
            local fh = io.open(c.path, "rb")
            if fh then
                fh:close()
                resolvedSh = c.busybox and ('"' .. c.path .. '" sh') or ('"' .. c.path .. '"')
                break
            end
        end

        local fallback = {
            HOME = realGetenv("USERPROFILE"),
            TMPDIR = realGetenv("TMPDIR") or realGetenv("TEMP") or realGetenv("TMP")
                     or ((realGetenv("USERPROFILE") or ".") .. "/tmp"),
            USER = realGetenv("USERNAME"),
            MUDSPOON_SH = resolvedSh or "sh",
        }
        os.getenv = function(k)
            return realGetenv(k) or fallback[k]
        end

        _G.__mudspoon_shResolved = (realGetenv("MUDSPOON_SH") ~= nil) or (resolvedSh ~= nil)
    end
-- END --

-- os.rename replaces an existing destination (POSIX rename) --
    if package.config:sub(1, 1) == "\\" then
        local ffi = require("ffi")

        ffi.cdef[[
int MoveFileExA(const char*, const char*, unsigned long);
]]

        local MOVEFILE_REPLACE_EXISTING = 0x1

        local MOVEFILE_COPY_ALLOWED = 0x2

        local realRename = os.rename

        os.rename = function(from, to)
            local flags = MOVEFILE_REPLACE_EXISTING + MOVEFILE_COPY_ALLOWED

            if ffi.C.MoveFileExA(tostring(from), tostring(to), flags) ~= 0 then return true end

            return realRename(from, to)
        end
    end
-- END --

-- Persistent logging: tee every diagnostic write to a logfile --
    do
        local logPath = hsDir .. "/hammerspoon.log"
        local lf = io.open(logPath, "a")
        if lf then
            lf:write("\n===== hammerspoon boot " .. os.date("%Y-%m-%d %H:%M:%S") .. " =====\n")
            lf:flush()

            local tail = {}

            _G.__mudspoon_log = {
                tail = tail,
                sink = nil
            }

            -- Keeps the newest chunks for the console and forwards each to the live sink
            local function record(...)
                local parts = {}
                for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
                local text = table.concat(parts)

                tail[#tail + 1] = text
                if #tail > 2000 then
                    local n = #tail

                    table.move(tail, 1001, n, 1)

                    for i = n - 999, n do tail[i] = nil end
                end

                local sink = _G.__mudspoon_log.sink
                if sink then pcall(sink, text) end
            end

            -- Replaces io.stdout and io.stderr with tables that tee writes into the log
            local function proxy(real)
                return {
                    write = function(self, ...)
                        lf:write(...)
                        lf:flush()
                        record(...)
                        real:write(...)

                        return self
                    end,
                    flush = function(self)
                        lf:flush()
                        real:flush()

                        return self
                    end,
                    close = function() end
                }
            end

            io.stdout = proxy(io.stdout)
            io.stderr = proxy(io.stderr)
            io.write  = function(...) return io.stdout:write(...) end

            -- Routes print through the tee
            print = function(...)
                local parts = {}
                for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
                io.stdout:write(table.concat(parts, "\t"), "\n")
            end

            -- Native crash capture (Windows only; a no-op elsewhere). Best-effort:
            -- the handlers run tiny Lua after the fault, so keep them minimal and
            -- pcall-guarded -- worst case they add nothing, they never make it worse.
            local IS_WINDOWS = package.config:sub(1, 1) == "\\"
            local hasFFI, ffi = pcall(require, "ffi")
            if IS_WINDOWS and hasFFI then
                pcall(function()
                    ffi.cdef[[
                        typedef unsigned long DWORD;
                        typedef long LONG;
                        typedef struct _EXREC {
                            DWORD ExceptionCode; DWORD ExceptionFlags;
                            struct _EXREC* ExceptionRecord; void* ExceptionAddress;
                            DWORD NumberParameters; size_t ExceptionInformation[15];
                        } EXCEPTION_RECORD;
                        typedef struct { EXCEPTION_RECORD* ExceptionRecord; void* ContextRecord; } EXCEPTION_POINTERS;
                        typedef LONG (*TOPFILT)(EXCEPTION_POINTERS*);
                        TOPFILT SetUnhandledExceptionFilter(TOPFILT);
                        typedef void (*SIGH)(int);
                        SIGH signal(int, SIGH);
                    ]]
                    local kernel32 = ffi.C
                    local ok = pcall(function() return kernel32.SetUnhandledExceptionFilter end)
                    if not ok then kernel32 = ffi.load("kernel32") end

                    -- Unhandled structured exception (access violation, etc.). Return 1
                    -- (EXCEPTION_EXECUTE_HANDLER) so the process ends after we log.
                    local filt = ffi.cast("TOPFILT", function(info)
                        pcall(function()
                            local code = 0
                            if info ~= nil and info.ExceptionRecord ~= nil then
                                code = tonumber(info.ExceptionRecord.ExceptionCode) or 0
                            end
                            lf:write(("\n*** hammerspoon: UNHANDLED WIN32 EXCEPTION 0x%08X"
                                .. " -- process aborting ***\n"):format(code))
                            if code == 0xC0000005 then
                                lf:write("    (0xC0000005 = access violation -- typically a bad "
                                    .. "FFI/COM vtable call, e.g. the WebView2 binding)\n")
                            end
                            lf:flush()
                        end)
                        return 1
                    end)
                    kernel32.SetUnhandledExceptionFilter(filt)

                    -- SIGABRT from the CRT. SIGABRT == 22 on Win.
                    local abrt = ffi.cast("SIGH", function()
                        pcall(function()
                            lf:write("\n*** hammerspoon: SIGABRT -- abort() ***\n")
                            lf:flush()
                        end)
                    end)
                    local sig = ffi.C.signal
                    sig(22, abrt)

                    -- The casts must outlive this scope or the callbacks are GC'd.
                    _G.__mudspoon_crashcbs = { filt, abrt }
                end)
            end
        end
    end
-- END --

-- DIAGNOSTIC: trap os.exit so a boot-time quit reveals WHO called it --
    do
        local realExit = os.exit
        os.exit = function(code, ...)
            io.stderr:write("[hammerspoon] *** os.exit(" .. tostring(code)
                .. ") called ***\n" .. debug.traceback("", 2) .. "\n")
            io.stderr:flush()
            return realExit(code, ...)
        end
    end
-- END --

-- Per-monitor DPI awareness (Windows): draw at native pixels, not OS bitmap-stretch --
    -- A DPI-UNAWARE process on a scaled display (e.g. 1920x1080 @ 125%) has EVERY
    -- window magnified by the OS -> oversized + blurry text and jagged rounded corners,
    -- across the shell webview AND canvas alerts. Declaring awareness makes Windows hand
    -- us real device pixels; the hs layer then speaks logical units and scales at the
    -- window boundary (hs.dpiscale + hs.screen/canvas/webview). MUST run before the
    -- first window/DC, so do it here at boot, before init.lua.
    --
    -- MASTER SWITCH + ROLLBACK: set MUDSPOON_HIDPI=0 to skip this. With awareness off,
    -- hs.dpiscale reports 1.0 and every scale becomes identity -- i.e. the old
    -- (blurry-but-working) behaviour -- so this one gate reverts the whole hi-dpi path.
    if package.config:sub(1, 1) == "\\" and os.getenv("MUDSPOON_HIDPI") ~= "0" then
        local okffi, ffi = pcall(require, "ffi")
        if okffi then
            pcall(function()
                ffi.cdef[[
                    int  SetProcessDpiAwarenessContext(void*);  /* user32, Win10 1703+ */
                    long SetProcessDpiAwareness(int);           /* shcore, Win8.1      */
                    int  SetProcessDPIAware(void);              /* user32, Vista+      */
                ]]
                local u32 = ffi.load("user32")
                -- Newest first: PER_MONITOR_AWARE_V2 = (DPI_AWARENESS_CONTEXT)-4.
                local ok, res = pcall(function()
                    return u32.SetProcessDpiAwarenessContext(ffi.cast("void*", -4))
                end)
                if not (ok and res ~= 0) then
                    -- shcore PROCESS_PER_MONITOR_DPI_AWARE = 2, then the Vista system-DPI call.
                    if not pcall(function() ffi.load("shcore").SetProcessDpiAwareness(2) end) then
                        pcall(function() u32.SetProcessDPIAware() end)
                    end
                end
            end)
        end
    end
-- END --

-- Assemble hs and expose it as a global --
    local hs = require("hs")
    _G.hs = hs
-- END --

-- Wire real modules --
    local ENABLE_WEBVIEW = os.getenv("MUDSPOON_WEBVIEW") == "1"

    local realExtra = { "alert", "json", "execute", "fs", "canvas", "geometry", "window", "application",
        "pasteboard", "urlevent", "http", "task", "menubar", "notify", "dialog", "sound",
        "audiodevice", "websocket", "pathwatcher", "axuielement", "uielement", "focus",
        "distributednotifications", "processInfo", "image", "settings", "socket", "chooser", "hash",
        "host", "caffeinate" }
    if ENABLE_WEBVIEW then realExtra[#realExtra + 1] = "webview" end
    for _, name in ipairs(realExtra) do
        hs[name] = require("hs." .. name)
    end

    package.preload["hs.eventtap"] = function() return hs.eventtap end
-- END --

-- Route os.execute through the POSIX sh too (Windows) --
    if package.config:sub(1, 1) == "\\" then
        local realOsExecute = os.execute
        os.execute = function(command)
            if command == nil then return true end

            local _, status = hs.execute(command, true)

            if status then return true, "exit", 0 end

            return nil, "exit", 1
        end

        _G.__mudspoon_realOsExecute = realOsExecute
    end
-- END --

-- Black-hole stub: callable, chainable, indexes to more of itself --
    -- hs.foo.bar(x):baz() and hs.foo(x) all no-op and return the same stub, so any
    -- access pattern survives module load. It returns a table, so a call site that
    -- then does arithmetic/string ops on the result will error -- which is exactly
    -- the "first real blocker" signal stub-and-boot is meant to surface.
    local function blackhole(name)
        local t = {}
        setmetatable(t, {
            -- Every field IS the same stub (so both namespace access -- foo.bar.baz
            -- -- and method access -- foo.get() -- keep resolving), and the stub is
            -- callable (so foo.get(x) and foo(x) no-op to the stub again).
            __index    = function() return t end,
            __call     = function() return t end,
            __tostring = function() return "<hs stub: " .. name .. ">" end,
        })
        return t
    end
-- END --

-- Modules not built yet --
    -- Prune a name the moment its real hs/<name>.lua exists (a preload entry would
    -- otherwise shadow the real file). Submodules ("window.filter") get their own
    -- entry because require() resolves them by full name.
    local STUB_MODULES = {}

    -- Webview: stub it UNLESS MUDSPOON_WEBVIEW=1 wired the real module above. The
    -- black-hole makes hs.webview.new()/usercontent no-op instead of running COM.
    if not ENABLE_WEBVIEW then
        STUB_MODULES[#STUB_MODULES + 1] = "webview"
        STUB_MODULES[#STUB_MODULES + 1] = "webview.usercontent"
    end

    for _, name in ipairs(STUB_MODULES) do
        local full = "hs." .. name
        local stub = blackhole(full)
        package.preload[full] = function() return stub end  -- satisfies require()
        -- Also hang it on the hs table for global `hs.<name>` access. Nested names
        -- ("window.filter") attach onto their parent (stubbed or real).
        local parent, leaf = name:match("^(.*)%.([^.]+)$")
        if parent then
            local p = hs[parent]
            if type(p) == "table" then p[leaf] = stub end
        else
            hs[name] = stub
        end
    end
-- END --

-- hs.ipc: the hs.cmd endpoint, started at boot only when MUDSPOON_IPC=1 --
    if os.getenv("MUDSPOON_IPC") == "1" then
        hs.ipc = require("hs.ipc")
    end
-- END --

-- Host-provided hs fields Hammerspoon.app normally sets (not modules) --
    hs.configdir = hsDir

    local ENTRY = hsDir .. "/init.lua"

    -- Libraries that must never be evicted (name -> true)
    local PROTECTED_LOADED = {
        string = true, table = true, math = true, io = true, os = true,
        coroutine = true, debug = true, package = true, ["package.preload"] = true,
        ffi = true, cffi = true, utf8 = true, _G = true,
    }

    local function isProtected(name)
        if PROTECTED_LOADED[name] then return true end
        -- Engine shims: "hs" and anything under "hs." (hs.timer, hs.window, ...).
        if name == "hs" or name:sub(1, 3) == "hs." then return true end
        return false
    end

    -- Runs hs.shutdownCallback once under pcall, then clears it
    local function runShutdownCallback()
        local cb = hs.shutdownCallback

        hs.shutdownCallback = nil

        if type(cb) ~= "function" then return end

        local okcb, cberr = pcall(cb)

        if not okcb then io.stderr:write("hs.shutdownCallback error: " .. tostring(cberr) .. "\n") end
    end

    function hs.reload()
        runShutdownCallback()

        -- Evict config modules so require() re-reads them from disk on re-run.
        local evicted = {}
        for name in pairs(package.loaded) do
            if not isProtected(name) then evicted[#evicted + 1] = name end
        end
        for _, name in ipairs(evicted) do package.loaded[name] = nil end
        io.stdout:write("[hammerspoon] hs.reload: evicted "
            .. #evicted .. " config module(s); re-running init.lua\n")
        io.stdout:flush()

        local chunk, err = loadfile(ENTRY)
        if not chunk then io.stderr:write("hs.reload: " .. tostring(err) .. "\n"); return end
        local ok, rerr = pcall(chunk)
        if not ok then io.stderr:write("hs.reload error: " .. tostring(rerr) .. "\n") end
    end

    hs.accessibilityState = function() return true end

    hs.console = setmetatable({}, {
        __index = function(_, key) return require("hs.console")[key] end
    })

    hs.openConsole = function(...) return require("hs.console").open(...) end

    hs.closeConsole = function() return require("hs.console").close() end

    -- Opens a file, folder or URL with its default handler
    hs.open = function(target)
        if type(target) ~= "string" or target == "" then return false end

        local file = target:find("^%a[%w+.-]*://") and target or target:gsub("/", "\\")

        return require("hs.shims").launch({
            file = file,
        }) == 0
    end
-- END --

-- hs.loadSpoon --
    package.path = package.path .. ";" .. hsDir .. "/Spoons/?.spoon/init.lua"

    _G.spoon = _G.spoon or {}

    hs.loadSpoon = function(name, global)
        print("-- Loading Spoon: " .. tostring(name))

        local ok, obj = pcall(require, name)

        if not ok then error("hs.loadSpoon: unable to load " .. tostring(name) .. ": " .. tostring(obj), 2) end

        if type(obj) ~= "table" then return obj end

        local path = package.searchpath(name, package.path)

        obj.spoonPath = path and path:gsub("\\", "/"):match("^(.*/)") or (hsDir .. "/Spoons/" .. name .. ".spoon/")

        if type(obj.init) == "function" then obj:init() end

        if global ~= false then _G.spoon[name] = obj end

        return obj
    end
-- END --

-- Windows os.execute: service `kill [-N] <pid>` natively --
    if package.config:sub(1, 1) == "\\" then
        local ok, ffi = pcall(require, "ffi")
        if ok then
            pcall(ffi.cdef, "void* OpenProcess(unsigned long, int, unsigned long);")
            pcall(ffi.cdef, "int CloseHandle(void*);")
            pcall(ffi.cdef, "int TerminateProcess(void*, unsigned int);")

            local K = ffi.load("kernel32")
            local PROCESS_TERMINATE = 0x0001
            local _osexecute = os.execute

            os.execute = function(cmd)
                if type(cmd) == "string" then
                    local pid = cmd:match("^%s*kill%s+%-%d+%s+(%d+)")
                        or cmd:match("^%s*kill%s+(%d+)")
                    if pid then
                        local h = K.OpenProcess(PROCESS_TERMINATE, 0, tonumber(pid))
                        if h == nil then return nil, "exit", 1 end
                        local killed = K.TerminateProcess(h, 9)
                        K.CloseHandle(h)
                        if killed ~= 0 then return true, "exit", 0 end

                        return nil, "exit", 1
                    end
                end
                return _osexecute(cmd)
            end
        end
    end
-- END --

-- Windows hs.relaunch: quit this host and boot a fresh one through launch.ps1 --
    -- Hammerspoon's hs.relaunch quits and reopens the app. The UI needs launch.ps1's
    -- environment (WebView2 DLL path, MUDSPOON_WEBVIEW) to come up, so relaunch runs
    -- through it. A detached PowerShell waits for THIS pid to exit, then boots a fresh
    -- host. Waiting first keeps the single-instance guard from evicting the newcomer.
    if package.config:sub(1, 1) == "\\" then
        hs.relaunch = function()
            runShutdownCallback()

            local pid    = (hs.processInfo and hs.processInfo.processID) or 0
            local mainDir = (arg[0] or "main.lua"):gsub("[^/\\]*$", "")
            local script  = hsDir .. "/.hs_relaunch.ps1"

            local f = io.open(script, "w")
            if f then
                if pid > 0 then
                    f:write("$p = " .. pid .. "\n")
                    f:write("while (Get-Process -Id $p -ErrorAction SilentlyContinue) "
                        .. "{ Start-Sleep -Milliseconds 150 }\n")
                else
                    f:write("Start-Sleep -Milliseconds 500\n")
                end
                f:write("& '" .. mainDir .. "launch.ps1' -SkipDeps\n")
                f:close()

                -- Real cmd os.execute: the override above routes os.execute through sh.
                local realExec = _G.__mudspoon_realOsExecute or os.execute
                realExec('start "" powershell -NoProfile -ExecutionPolicy Bypass '
                    .. '-WindowStyle Hidden -File "' .. script .. '"')
            end

            os.exit(0)
        end
    end
-- END --

-- Smoke-test hook: run the cross-platform hs.* suite instead of booting the config --
    do
        local smoke = os.getenv("MUDSPOON_SMOKE")
        if smoke and smoke ~= "" then
            io.stdout:write("[hammerspoon] MUDSPOON_SMOKE set -- running smoke suite: " .. smoke .. "\n")
            io.stdout:flush()
            local schunk, serr = loadfile(smoke)
            if not schunk then
                io.stderr:write("[hammerspoon] cannot load smoke suite " .. smoke .. ": " .. tostring(serr) .. "\n")
                os.exit(2)
            end
            local sok, scode = pcall(schunk)
            if not sok then
                io.stderr:write("[hammerspoon] smoke suite raised: " .. tostring(scode) .. "\n")
                os.exit(2)
            end
            os.exit(tonumber(scode) or 0)
        end
    end
-- END --

-- Windows font install --
    if package.config:sub(1, 1) == "\\" then
        pcall(function()
            local ffi = require("ffi")
            local fs  = require("hs.fs")

            local srcDir = hsDir .. "/ui/fonts"
            if not fs.attributes(srcDir) then return end

            local localApp = os.getenv("LOCALAPPDATA")
            if not localApp or localApp == "" then return end
            local dstDir = localApp:gsub("\\", "/") .. "/Microsoft/Windows/Fonts"

            pcall(ffi.cdef, "int AddFontResourceA(const char*);")
            pcall(ffi.cdef, "long SendMessageTimeoutA(void*, unsigned int, uintptr_t, uintptr_t, unsigned int, unsigned int, uintptr_t*);")

            local gdi      = ffi.load("gdi32")
            local user     = ffi.load("user32")
            local realExec = _G.__mudspoon_realOsExecute or os.execute
            local REG      = "HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts"

            local function copyFile(src, dst)
                local fin = io.open(src, "rb")
                if not fin then return false end
                local data = fin:read("*all")
                fin:close()
                local fout = io.open(dst, "wb")
                if not fout then return false end
                fout:write(data)
                fout:close()
                return true
            end

            realExec('mkdir "' .. dstDir:gsub("/", "\\") .. '" >nul 2>nul')

            local broadcast = false

            for file in fs.dir(srcDir) do
                local ext = file:match("%.([^%.]+)$")
                ext = ext and ext:lower()
                if ext == "ttf" or ext == "otf" then
                    local dst    = dstDir .. "/" .. file
                    local dstWin = dst:gsub("/", "\\")

                    if not fs.attributes(dst) and copyFile(srcDir .. "/" .. file, dst) then
                        local base  = file:gsub("%.[^%.]+$", "")
                        local label = base .. (ext == "otf" and " (OpenType)" or " (TrueType)")
                        realExec('reg add "' .. REG .. '" /v "' .. label
                            .. '" /t REG_SZ /d "' .. dstWin .. '" /f >nul 2>nul')
                        broadcast = true
                    end

                    if fs.attributes(dst) then gdi.AddFontResourceA(dstWin) end
                end
            end

            if broadcast then
                local WM_FONTCHANGE  = 0x001D
                local HWND_BROADCAST = ffi.cast("void*", 0xFFFF)
                local res = ffi.new("uintptr_t[1]")
                user.SendMessageTimeoutA(HWND_BROADCAST, WM_FONTCHANGE, 0, 0, 0x0002, 1000, res)
            end
        end)
    end
-- END --

-- Boot: run the entry file, then drive the runloop --
    local initFile = io.open(ENTRY, "r")

    if initFile then
        initFile:close()

        io.stdout:write("[hammerspoon] booting from " .. hsDir .. "\n")

        local chunk, lerr = loadfile(ENTRY)
        if not chunk then
            io.stderr:write("[hammerspoon] cannot load " .. ENTRY .. ": " .. tostring(lerr) .. "\n")
            os.exit(1)
        end

        local ok, rerr = pcall(chunk)
        if not ok then
            io.stderr:write("[hammerspoon] init.lua raised: " .. tostring(rerr) .. "\n")
            os.exit(1)
        end

        io.stdout:write("[hammerspoon] init.lua loaded; entering runloop (Ctrl+C to quit).\n")
    else
        io.stdout:write("[hammerspoon] no init.lua in " .. hsDir .. "; entering runloop\n")
    end

    io.stdout:flush()

    -- Runloop heartbeat (diagnostic): logs once a second so the log shows whether the
    -- loop keeps ticking. If ticks CONTINUE past webview bring-up, the process is alive
    -- and any "no window" is a visibility/choreography issue; if ticks STOP at bring-up,
    -- the process died there via a path below our os.exit/SEH hooks (e.g. a COM
    -- fail-fast). OFF by default now that the runloop is proven; set
    -- MUDSPOON_HEARTBEAT=1 to re-enable.
    if os.getenv("MUDSPOON_HEARTBEAT") == "1" then
        local n = 0
        hs.timer.doEvery(1.0, function()
            n = n + 1
            io.stderr:write("[hammerspoon] runloop heartbeat " .. n .. "\n")
        end)
    end

    local t0 = os.clock()
    hs.run()
    io.stdout:write(("[hammerspoon] hs.run() RETURNED after %.3fs -- runloop stopped "
        .. "(something called hs.stop/shutdown). Not an os.exit.\n"):format(os.clock() - t0))
-- END --
