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

-- Locate the trees + the HOME mudscript installs under --
    -- This file sits at the mudspoon repo root; hs/ is beside it.
    local here = (arg[0] or "run_mudscript.lua"):gsub("[^/\\]*$", "")
    if here == "" then here = "./" end

    -- mudscript installs into $HOME/.hammerspoon (see mac/install.sh) and addresses
    -- itself through os.getenv("HOME").."/.hammerspoon/..." all over, NOT hs.configdir.
    -- So HOME is the anchor. On the rig it is the dir CONTAINING .hammerspoon.
    local homeDir = arg[1]
                  or os.getenv("MUDSCRIPT_HOME")
                  or (here .. "../mudscript")
    homeDir = homeDir:gsub("[/\\]+$", "")            -- strip trailing slash

    local hsDir = homeDir .. "/.hammerspoon"          -- the actual config/install dir
-- END --

-- Make os.getenv("HOME") resolve (Windows has USERPROFILE, not HOME) --
    -- Shimmed rather than set via _putenv: LuaJIT's os.getenv reads the CRT env, and
    -- which CRT wins is fragile on Windows. A wrapper is portable and total: mac/ sees
    -- HOME (and a TMPDIR) no matter the host. Real vars still win when present.
    do
        local realGetenv = os.getenv
        local fallback = {
            HOME   = homeDir,
            TMPDIR = realGetenv("TMPDIR") or realGetenv("TEMP") or realGetenv("TMP")
                     or (homeDir .. "/tmp"),
        }
        os.getenv = function(k) return realGetenv(k) or fallback[k] end
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

-- Assemble hs and expose it as a global (mac/ uses `hs` unqualified) --
    local hs = require("hs")
    _G.hs = hs
-- END --

-- Wire real modules the frozen init.lua does not assemble itself --
    -- init.lua (frozen) only wires the A-G packets + eventtap + hotkey. These leaf
    -- modules exist as files but aren't hung on `hs`, and mac/ reaches them through
    -- the global (hs.json.encode, ...), so attach them here. require() also works on
    -- their own files; this only fills the global table.
    for _, name in ipairs({ "alert", "json", "execute", "fs", "webview", "canvas" }) do
        hs[name] = require("hs." .. name)
    end

    -- mac/ does require("hs.eventtap"), but the read side lives at hs/eventtap/tap.lua
    -- (there is no hs/eventtap.lua). init.lua already assembled the aggregate table
    -- as hs.eventtap (tap + .event); alias the bare require name to it via preload.
    package.preload["hs.eventtap"] = function() return hs.eventtap end
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
        "application", "window", "window.filter", "menubar",
        "uielement", "axuielement", "dialog", "focus", "http", "task",
        "audiodevice", "urlevent", "sound", "pasteboard", "processInfo",
        "geometry", "chooser", "notify",
    }

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

    -- reload: re-run the entry file in place. Good enough for the config-reload the
    -- shell triggers; a fuller version would tear down state first.
    local ENTRY = hsDir .. "/init.lua"
    function hs.reload()
        local chunk, err = loadfile(ENTRY)
        if not chunk then io.stderr:write("hs.reload: " .. tostring(err) .. "\n"); return end
        local ok, rerr = pcall(chunk)
        if not ok then io.stderr:write("hs.reload error: " .. tostring(rerr) .. "\n") end
    end

    hs.accessibilityState = function() return true end   -- Win32 has no AX gate
    hs.openConsole        = function() end                 -- no console window yet
    hs.loadSpoon          = function() return nil end      -- plugins not wired yet
    hs.processInfo        = { bundleID = "org.mudspoon", processID = 0 }
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
    hs.run()
-- END --
