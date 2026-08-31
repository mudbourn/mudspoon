-- mudspoon: run mudscript's mac/ config under the hs.* layer (boot bootstrap) --
    -- The host glue that Hammerspoon.app normally provides: assemble `hs`, expose
    -- it as a GLOBAL (mudscript's mac/ code uses `hs` unqualified), point
    -- package.path at both trees, set the host-provided hs fields (configdir,
    -- reload, ...), then run mudscript's entry file on foundation's runloop.
    --
    -- STUB-AND-BOOT: modules mudscript needs that mudspoon hasn't built yet are
    -- installed here as black-hole stubs (see below) so mac/init.lua can load
    -- top-to-bottom. A stub survives require() and any chained access, but does
    -- nothing -- so the first place real behaviour is required surfaces as a clear
    -- runtime wall, not a load-time crash across 20 unbuilt modules. As each real
    -- module lands (a file in hs/), delete its name from STUB_MODULES below so the
    -- real one is used instead of the stub (preload shadows package.path).
    --
    -- Windows/rig only: requiring hs pulls foundation, which ffi.load()s user32 --
    -- this cannot run on macOS. Same console rules as the spikes (physical,
    -- foreground, not RDP).
    --
    -- Usage:  luajit run_mudscript.lua [MUDSCRIPT_ROOT]
    --   MUDSCRIPT_ROOT defaults to $MUDSCRIPT_HOME, else a sibling ../mudscript.
-- END --

-- Lua 5.2+ compat: table.pack / table.unpack on LuaJIT (5.1) --
    -- Hammerspoon's macOS LuaJIT is built with LUAJIT_ENABLE_LUA52COMPAT, so mac/ code
    -- freely calls table.pack / table.unpack (e.g. ms_devtools' console eval:
    -- `table.pack(pcall(fn))`). This rig's LuaJIT lacks that compat, so table.pack is
    -- nil ("attempt to call field 'pack' (a nil value)") and table.unpack is missing.
    -- Provide both, matching the reference semantics (pack sets the field `n`). Only
    -- fill gaps -- never clobber a real implementation if one is present.
    if not table.pack then
        table.pack = function(...)
            return { n = select("#", ...), ... }
        end
    end
    if not table.unpack then
        table.unpack = unpack   -- LuaJIT keeps the 5.1 global `unpack`
    end
-- END --

-- Locate the trees + the HOME mudscript installs under --
    -- This file sits at the mudspoon repo root; hs/ is beside it.
    local here = (arg[0] or "run_mudscript.lua"):gsub("[^/\\]*$", "")
    if here == "" then here = "./" end

    -- mudscript installs into $HOME/.hammerspoon (see mac/install.sh) and addresses
    -- itself through os.getenv("HOME").."/.hammerspoon/..." all over, NOT hs.configdir.
    -- So HOME is the anchor. On the rig it is the dir CONTAINING .hammerspoon.
    -- Default anchor: whichever candidate actually contains a .hammerspoon/init.lua.
    -- The tree used to live at ../mudscript/.hammerspoon; it now sits at ../.hammerspoon
    -- (a sibling of this repo). Probe the new layout first, then the legacy one, so a
    -- bare `luajit run_mudscript.lua` works either way. An explicit arg / MUDSCRIPT_HOME
    -- always wins.
    local function hasConfig(dir)
        local fh = io.open(dir .. "/.hammerspoon/init.lua", "r")
        if fh then fh:close(); return true end
        return false
    end
    local homeDir = arg[1]
                  or os.getenv("MUDSCRIPT_HOME")
                  or (hasConfig(here .. "..") and (here .. ".."))
                  or (here .. "../mudscript")
    homeDir = homeDir:gsub("[/\\]+$", "")            -- strip trailing slash

    local hsDir = homeDir .. "/.hammerspoon"          -- the actual config/install dir
-- END --

-- Capture C-level stderr (LuaJIT panics / CRT abort / fastfail) to a file --
    -- The detached launcher discards stderr, so a LuaJIT "PANIC: ..." or a CRT
    -- abort()/__fastfail -- which write to the C stderr FILE*, NOT through the app's
    -- own stdout logging -- vanished: a crash left hammerspoon.log simply stopping
    -- mid-line with no reason recorded. Rebind the process's stderr FILE* to
    -- data/stderr.log with freopen so any such write is preserved on disk. Append
    -- mode (not truncate) so a crash survives an immediate relaunch; a header marks
    -- each boot. Best-effort and non-fatal: guarded end-to-end, and a CRT without
    -- __acrt_iob_func (pre-UCRT msvcrt) simply skips. Lua's io.stderr wraps this same
    -- FILE*, so its :write()s follow along -- stderr is centralised here either way.
    pcall(function()
        local ffi = require("ffi")
        pcall(ffi.cdef, [[
            void* __acrt_iob_func(unsigned);
            void* freopen(const char*, const char*, void*);
            int   fputs(const char*, void*);
            int   fflush(void*);
        ]])
        local se = ffi.C.__acrt_iob_func(2)          -- stderr is iob index 2 on UCRT
        if se ~= nil and ffi.C.freopen(hsDir .. "/data/stderr.log", "a", se) ~= nil then
            ffi.C.fputs("\n===== stderr capture: boot " ..
                os.date("%Y-%m-%d %H:%M:%S") .. " (pid follows in log) =====\n", se)
            ffi.C.fflush(se)
        end
    end)
-- END --

-- Make os.getenv("HOME") resolve (Windows has USERPROFILE, not HOME) --
    -- Shimmed rather than set via _putenv: LuaJIT's os.getenv reads the CRT env, and
    -- which CRT wins is fragile on Windows. A wrapper is portable and total: mac/ sees
    -- HOME (and a TMPDIR) no matter the host. Real vars still win when present.
    do
        local realGetenv = os.getenv

        -- hs.execute routes mac/'s POSIX command strings through a real sh on
        -- Windows (see hs/execute.lua). It reads $MUDSPOON_SH. Locate a shell by
        -- probing, in order: a bundle beside this file at bin/, then the standard
        -- git-for-Windows install paths. Only used when MUDSPOON_SH is unset, so an
        -- explicit value in the real env always wins.
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

        -- HOME is the anchor the whole mac/ tree addresses itself through
        -- (os.getenv("HOME").."/.hammerspoon/..."), and homeDir is the dir we ACTUALLY
        -- booted .hammerspoon from (located by script position, not by HOME). These MUST
        -- agree. An inherited real HOME (git-for-Windows sets HOME=C:/Users/<user>) would
        -- otherwise win the fallback and send HOME-relative code -- notably ms_guardian's
        -- trusted-hash lookup -- to a DIFFERENT, empty .hammerspoon, which reads as an
        -- uninitialized manifest and BLOCKS boot. So HOME is a forced OVERRIDE here, not
        -- a fallback; TMPDIR/MUDSPOON_SH stay fallbacks (a real value should win).
        local override = { HOME = homeDir }
        local fallback = {
            TMPDIR = realGetenv("TMPDIR") or realGetenv("TEMP") or realGetenv("TMP")
                     or (homeDir .. "/tmp"),
            -- If nothing was found, fall back to bare `sh` (works if it is on PATH).
            -- When even that is absent, mac/'s file ops / guardian hashing no-op; a
            -- ONE-TIME warning is emitted below rather than per-call cmd.exe spam.
            MUDSPOON_SH = resolvedSh or "sh",
        }
        os.getenv = function(k)
            if override[k] ~= nil then return override[k] end
            return realGetenv(k) or fallback[k]
        end

        _G.__mudspoon_shResolved = (realGetenv("MUDSPOON_SH") ~= nil) or (resolvedSh ~= nil)
    end
-- END --

-- Persistent logging: tee every diagnostic write to a logfile --
    -- Until now output went ONLY to the console (io.stderr), so a boot-time panic
    -- or a window that closes takes its own error message with it. Tee stdout+stderr
    -- into <hsDir>/hammerspoon.log (appended each write, flushed immediately) so there
    -- is always a durable record to read after the fact. The console still echoes.
    --
    -- A true LuaJIT `PANIC:` or a Win32 access violation aborts BELOW the Lua io
    -- layer, so the tee alone can't see it. Rather than require a launch-time shell
    -- redirect, we fold the capture in (Windows only, further down this block): a
    -- Win32 unhandled-exception filter records the exception code (0xC0000005 = the
    -- access violation the COM/webview path throws) and a SIGABRT handler records
    -- LuaJIT's panic->abort. Both write a marker into the same logfile, so a hard
    -- crash still leaves a durable "it died HERE, with THIS code" line.
    do
        local logPath = hsDir .. "/hammerspoon.log"
        local lf = io.open(logPath, "a")
        if lf then
            lf:write("\n===== hammerspoon boot " .. os.date("%Y-%m-%d %H:%M:%S") .. " =====\n")
            lf:flush()
            -- File handles are userdata (no field assignment), so replace io.stdout/
            -- io.stderr with proxy TABLES that tee :write into the log then forward to
            -- the real stream. Only write/flush/close are used against these; forward
            -- those explicitly rather than proxy every FILE method.
            local function proxy(real)
                return {
                    write = function(self, ...) lf:write(...); lf:flush(); real:write(...); return self end,
                    flush = function(self) lf:flush(); real:flush(); return self end,
                    close = function() end,
                }
            end
            io.stdout = proxy(io.stdout)
            io.stderr = proxy(io.stderr)
            io.write  = function(...) return io.stdout:write(...) end
            -- print() writes to C stdout below the io layer; reroute it through the tee.
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

                    -- SIGABRT (LuaJIT panic -> abort, CRT assert). SIGABRT == 22 on Win.
                    local abrt = ffi.cast("SIGH", function()
                        pcall(function()
                            lf:write("\n*** hammerspoon: SIGABRT -- LuaJIT panic or abort() ***\n")
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
    -- mudscript exits via os.exit(0) in ms.shutdown/ms.restart. If the process
    -- quits right after boot, this prints the call site + stack before exiting, so
    -- we can see which path (guardian untrusted? a restart?) is firing.
    do
        local realExit = os.exit
        os.exit = function(code, ...)
            io.stderr:write("[run_mudscript] *** os.exit(" .. tostring(code)
                .. ") called ***\n" .. debug.traceback("", 2) .. "\n")
            io.stderr:flush()
            return realExit(code, ...)
        end
    end
-- END --

-- package.path: mudspoon hs/ first, then the .hammerspoon install (for lib.* requires) --
    -- require("hs.timer")        -> <mudspoon>/hs/timer.lua
    -- require("lib.ms_guardian") -> <home>/.hammerspoon/lib/ms_guardian.lua
    package.path = table.concat({
        here  .. "?.lua",
        here  .. "?/init.lua",
        hsDir .. "/?.lua",
        hsDir .. "/?/init.lua",
        package.path,
    }, ";")
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

-- Assemble hs and expose it as a global (mac/ uses `hs` unqualified) --
    local hs = require("hs")
    _G.hs = hs
-- END --

-- Wire real modules the frozen init.lua does not assemble itself --
    -- init.lua (frozen) only wires the A-G packets + eventtap + hotkey. These leaf
    -- modules exist as files but aren't hung on `hs`, and mac/ reaches them through
    -- the global (hs.json.encode, ...), so attach them here. require() also works on
    -- their own files; this only fills the global table.
    -- WEBVIEW is OPT-IN: set MUDSPOON_WEBVIEW=1 to attempt the real WebView2 COM
    -- bring-up (instrumented -- see hs/webview.lua's trace()). Left off, webview stays
    -- a black-hole stub (below) so a COM fault can't take down a boot. The module has
    -- never run on hardware; when enabled, the trace lines in hammerspoon.log pinpoint the
    -- last COM step reached before any crash (paired with the SEH exception-code line).
    local ENABLE_WEBVIEW = os.getenv("MUDSPOON_WEBVIEW") == "1"

    local realExtra = { "alert", "json", "execute", "fs", "canvas", "geometry", "window", "application",
        "pasteboard", "urlevent", "http", "task", "menubar", "notify", "dialog", "sound",
        "audiodevice", "websocket", "pathwatcher", "axuielement", "uielement", "focus",
        "distributednotifications" }
    if ENABLE_WEBVIEW then realExtra[#realExtra + 1] = "webview" end
    for _, name in ipairs(realExtra) do
        hs[name] = require("hs." .. name)
    end

    -- mac/ does require("hs.eventtap"), but the read side lives at hs/eventtap/tap.lua
    -- (there is no hs/eventtap.lua). init.lua already assembled the aggregate table
    -- as hs.eventtap (tap + .event); alias the bare require name to it via preload.
    package.preload["hs.eventtap"] = function() return hs.eventtap end
-- END --

-- Route os.execute through the POSIX sh too (Windows) --
    -- mac/ also shells out via os.execute (mkdir -p, chmod, rm -rf, ...) which goes
    -- STRAIGHT to cmd.exe and errors ("The syntax of the command is incorrect."), so
    -- those ops silently fail. hs.execute already routes through sh; delegate to it.
    -- Lua 5.1 os.execute returns a numeric code (0 = ok); map hs.execute's status to
    -- that. No-command call reports shell availability (non-zero). mac/unix keeps the
    -- native os.execute (hs.execute's mac path is the same popen shell anyway).
    if package.config:sub(1, 1) == "\\" then
        local realOsExecute = os.execute
        os.execute = function(command)
            if command == nil then return 1 end             -- "is a shell available?"
            local _, status = hs.execute(command, true)
            return status and 0 or 1
        end
        _G.__mudspoon_realOsExecute = realOsExecute          -- kept if ever needed
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

-- Modules mudscript uses that mudspoon has NOT built yet --
    -- Prune a name the moment its real hs/<name>.lua exists (a preload entry would
    -- otherwise shadow the real file). Submodules ("window.filter") get their own
    -- entry because require() resolves them by full name.
    local STUB_MODULES = {
        "processInfo",
        "chooser",
    }

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

-- Host-provided hs fields Hammerspoon.app normally sets (not modules) --
    -- configdir is a real STRING (mac/ concatenates paths onto it); the rest are
    -- lightweight host hooks stubbed until they earn a real implementation.
    hs.configdir = hsDir

    -- reload: drop the config's cached modules, then re-run the entry file so edits
    -- on disk actually take effect. init.lua only pulls its modules through require(),
    -- and Lua caches those in package.loaded -- so without clearing the cache a reload
    -- just re-requires the same in-memory copies and any file edit is ignored (the
    -- symptom "hs.reload() does not reload mudscript"). We evict every config-side
    -- module but PRESERVE the engine: the hs.* shims and the standard/FFI libraries.
    -- Re-requiring an hs.* module would re-run its ffi.cdef and throw on the duplicate
    -- typedef, and it holds live runtime state (timers, the runloop), so the engine
    -- stays put while only the mudscript layer is rebuilt.
    --
    -- Caveat: this does not tear down state the OLD config created (hotkeys, timers,
    -- menubars, watchers). mudscript is expected to reclaim those on load; a fuller
    -- reset would require the engine to track and release them here.
    local ENTRY = hsDir .. "/init.lua"

    -- Standard/JIT libraries that must never be evicted (name -> true).
    local PROTECTED_LOADED = {
        string = true, table = true, math = true, io = true, os = true,
        coroutine = true, debug = true, package = true, ["package.preload"] = true,
        ffi = true, jit = true, bit = true, utf8 = true, _G = true,
    }

    local function isProtected(name)
        if PROTECTED_LOADED[name] then return true end
        -- Engine shims: "hs" and anything under "hs." (hs.timer, hs.window, ...).
        if name == "hs" or name:sub(1, 3) == "hs." then return true end
        -- JIT sublibraries (jit.util, jit.opt, ...).
        if name:sub(1, 4) == "jit." then return true end
        return false
    end

    function hs.reload()
        -- Evict config modules so require() re-reads them from disk on re-run.
        local evicted = {}
        for name in pairs(package.loaded) do
            if not isProtected(name) then evicted[#evicted + 1] = name end
        end
        for _, name in ipairs(evicted) do package.loaded[name] = nil end
        io.stdout:write("[run_mudscript] hs.reload: evicted "
            .. #evicted .. " config module(s); re-running init.lua\n")
        io.stdout:flush()

        local chunk, err = loadfile(ENTRY)
        if not chunk then io.stderr:write("hs.reload: " .. tostring(err) .. "\n"); return end
        local ok, rerr = pcall(chunk)
        if not ok then io.stderr:write("hs.reload error: " .. tostring(rerr) .. "\n") end
    end

    hs.accessibilityState = function() return true end   -- Win32 has no AX gate
    hs.openConsole        = function() end                 -- no console window yet
    hs.loadSpoon          = function() return nil end      -- plugins not wired yet
    -- processID: the real Win32 PID (mudscript reads hs.processInfo.processID).
    -- GetCurrentProcessId returns DWORD; declared with a plain type, no typedef, so
    -- it cannot collide with any module's cdef. Falls back to 0 if the call fails.
    local realPID = 0
    pcall(function()
        ffi.cdef("unsigned long GetCurrentProcessId(void);")
        realPID = tonumber(ffi.load("kernel32").GetCurrentProcessId())
    end)
    hs.processInfo        = { bundleID = "org.hammerspoon.Hammerspoon", processID = realPID }
-- END --

-- Smoke-test hook: run the cross-platform hs.* suite instead of booting mudscript --
    -- Set MUDSPOON_SMOKE=<abs path to test/smoke.lua> to run the parity/functionality
    -- suite against the SAME assembled `hs` mudscript sees (all realExtra modules + host
    -- fields wired above), then exit -- WITHOUT loading mudscript's init.lua/UI. The suite
    -- drives its own runloop for async tests and os.exit()s with 0 (all pass) or 1 (any
    -- failure); a load/raise here exits 2. See test/README.md.
    do
        local smoke = os.getenv("MUDSPOON_SMOKE")
        if smoke and smoke ~= "" then
            io.stdout:write("[run_mudscript] MUDSPOON_SMOKE set -- running smoke suite: " .. smoke .. "\n")
            io.stdout:flush()
            local schunk, serr = loadfile(smoke)
            if not schunk then
                io.stderr:write("[run_mudscript] cannot load smoke suite " .. smoke .. ": " .. tostring(serr) .. "\n")
                os.exit(2)
            end
            local sok, scode = pcall(schunk)
            if not sok then
                io.stderr:write("[run_mudscript] smoke suite raised: " .. tostring(scode) .. "\n")
                os.exit(2)
            end
            os.exit(tonumber(scode) or 0)
        end
    end
-- END --

-- Boot: run the entry file, then drive the runloop --
    io.stdout:write("[run_mudscript] booting mudscript from " .. hsDir .. "\n")

    local chunk, lerr = loadfile(ENTRY)
    if not chunk then
        io.stderr:write("[run_mudscript] cannot load " .. ENTRY .. ": " .. tostring(lerr) .. "\n")
        os.exit(1)
    end

    local ok, rerr = pcall(chunk)
    if not ok then
        io.stderr:write("[run_mudscript] init.lua raised: " .. tostring(rerr) .. "\n")
        os.exit(1)
    end

    io.stdout:write("[run_mudscript] init.lua loaded; entering runloop (Ctrl+C to quit).\n")
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
            io.stderr:write("[run_mudscript] runloop heartbeat " .. n .. "\n")
        end)
    end

    local t0 = os.clock()
    hs.run()
    -- If we get here, hs.run() RETURNED (the loop's `running` went false) rather than
    -- the process being killed by os.exit. The elapsed time says immediate (guard /
    -- instant stop) vs ran-a-while.
    io.stdout:write(("[run_mudscript] hs.run() RETURNED after %.3fs -- runloop stopped "
        .. "(something called hs.stop/shutdown). Not an os.exit.\n"):format(os.clock() - t0))
-- END --
