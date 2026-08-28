-- =============================================================================
-- smoke.lua -- cross-platform hs.* parity + functionality smoke suite
-- =============================================================================
-- Runs UNCHANGED under real Hammerspoon (macOS) and mudspoon (Windows/LuaJIT).
-- It assumes a global `hs` is already assembled (true inside Hammerspoon; true
-- after run_mudscript.lua wires the port), exercises the hs.* surface mudscript
-- actually depends on, and writes a structured JSON report that can be diffed
-- Mac-vs-Windows to separate real PARITY GAPS from platform-inherent differences.
--
-- How to run:
--   Windows/mudspoon:  set MUDSPOON_SMOKE=<abs path to this file>, then launch
--                      `luajit run_mudscript.lua`  (see test/smoke_win.ps1).
--   macOS/Hammerspoon: `hs -c "dofile('<abs path>')"` (see test/smoke_mac.sh),
--                      requires Hammerspoon's command-line tool / ipc.
--
-- Output:  a report JSON at $MUDSPOON_SMOKE_OUT, else
--          <hs.configdir>/smoke_report_<host>.json, plus a console summary.
--          Diff two reports with test/diff_smoke.lua.
--
-- Contract:  Lua 5.1 (LuaJIT) AND 5.4 compatible -- no goto, no `//`, no bitops,
--            no `math.type`; `table.unpack or unpack`. Every check is pcall-wrapped
--            so a missing symbol is RECORDED, never fatal: the suite's whole job is
--            to discover gaps, not assume them.
-- =============================================================================

local hs = _G.hs
assert(hs, "smoke.lua: global `hs` not found -- run inside Hammerspoon, or via the "
        .. "run_mudscript.lua MUDSPOON_SMOKE hook on Windows.")

local unpack      = table.unpack or unpack
local IS_WINDOWS  = package.config:sub(1, 1) == "\\"

-- mudspoon exposes a user-callable hs.run() (the foundation pump) and is the only
-- host that currently runs on Windows; real Hammerspoon has no hs.run (its runloop
-- is the app's). So "should we drive the runloop for async tests?" == mudspoon.
local DRIVE_RUNLOOP = IS_WINDOWS and type(hs.run) == "function"

local function detectHost()
    if _G.__mudspoon_shResolved ~= nil or _G.__mudspoon_crashcbs ~= nil then return "mudspoon" end
    if type(hs.processInfo) == "table" and hs.processInfo.bundlePath then return "hammerspoon" end
    return IS_WINDOWS and "mudspoon" or "hammerspoon"
end
local HOST     = detectHost()
-- Config comes from env OR globals: the macOS `hs` CLI evaluates this file inside
-- Hammerspoon's own process, where shell env vars are invisible, so the Mac
-- launcher injects options as globals (`hs -c "MUDSPOON_SMOKE_NET=true; dofile(...)"`).
local WANT_NET = os.getenv("MUDSPOON_SMOKE_NET") == "1" or _G.MUDSPOON_SMOKE_NET == true

-- -----------------------------------------------------------------------------
-- Framework
-- -----------------------------------------------------------------------------
local results   = {}     -- array of records
local pending   = 0      -- outstanding async tests
local finalized = false

local function record(mod, name, kind, status, detail, observed)
    results[#results + 1] = {
        id       = mod .. "." .. name,
        module   = mod,
        name     = name,
        kind     = kind,             -- "contract" | "behavior" | "behavior-async"
        status   = status,           -- "pass" | "fail" | "skip" | "error" | "timeout"
        detail   = detail,           -- message on non-pass (or nil)
        observed = observed,         -- normalized value for parity diffing (or nil)
    }
end

-- Assertions throw a tagged table; run() turns it into a fail/skip record.
local function fail(msg) error({ smoke = true, msg = msg }, 0) end
local function skip(msg) error({ smoke = true, skip = true, msg = msg }, 0) end

local function need(cond, msg) if not cond then fail(msg) end end
local function needType(v, ty, what)
    if type(v) ~= ty then fail((what or "value") .. " expected " .. ty .. ", got " .. type(v)) end
    return v
end

-- A synchronous test. fn may return an "observed" value (recorded on pass).
local function test(mod, name, kind, fn)
    local ok, res = pcall(fn)
    if ok then
        record(mod, name, kind, "pass", nil, res)
    elseif type(res) == "table" and res.smoke then
        record(mod, name, kind, res.skip and "skip" or "fail", res.msg)
    else
        record(mod, name, kind, "error", tostring(res))
    end
end

local function maybeFinalize() end   -- forward decl (set below)

-- An async test. fn(done) must eventually call done(status, detail, observed).
-- A timeout guard fires if it never does.
local function testAsync(mod, name, fn, timeout)
    if not (type(hs.timer) == "table" and type(hs.timer.doAfter) == "function") then
        record(mod, name, "behavior-async", "skip", "hs.timer.doAfter unavailable")
        return
    end
    pending = pending + 1
    local done_called = false
    local function done(status, detail, observed)
        if done_called then return end
        done_called = true
        record(mod, name, "behavior-async", status, detail, observed)
        pending = pending - 1
        maybeFinalize()
    end
    hs.timer.doAfter(timeout or 3.0, function()
        done("timeout", "no completion within " .. tostring(timeout or 3.0) .. "s")
    end)
    local ok, err = pcall(fn, done)
    if not ok then done("error", tostring(err)) end
end

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------
local function nav(path)
    local cur = hs
    for seg in path:gmatch("[^.]+") do
        if type(cur) ~= "table" then return nil, "hs." .. path .. ": ancestor '" .. seg .. "' not indexable" end
        cur = cur[seg]
        if cur == nil then return nil, "hs." .. path .. " is nil" end
    end
    return cur
end

local function deepEqual(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not deepEqual(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local function approx(a, b, eps) return math.abs(a - b) <= (eps or 0.5) end

local function tmpBase()
    local base = os.getenv("MUDSPOON_SMOKE_OUT") and "" or ""  -- (unused; kept for clarity)
    base = os.getenv("TMPDIR") or os.getenv("TMP") or os.getenv("TEMP") or "/tmp"
    return (base:gsub("[/\\]+$", ""))
end

-- -----------------------------------------------------------------------------
-- CONTRACT: presence + type of every hs.* symbol mudscript reaches.
--   {dotted path, expected type, scope}   scope: "both"(default)|"mudspoon"|"hammerspoon"
--   type "callable" accepts function OR table (module tables that are __call-able).
-- -----------------------------------------------------------------------------
-- This list is grep-derived from mudscript's mac/ tree (every hs.a.b symbol it
-- calls), NOT guessed -- an unused symbol here would show as a false parity gap.
-- Regenerate with: grep -rhoE "hs\.[a-zA-Z]+(\.[a-zA-Z]+){1,2}" mac --include=*.lua | sort -u
local CONTRACT = {
    -- timers / json / shell / fs
    { "timer.doAfter", "function" }, { "timer.doEvery", "function" },
    { "timer.usleep", "function" },  { "timer.secondsSinceEpoch", "function" },
    { "timer.absoluteTime", "function" },
    { "json.encode", "function" },   { "json.decode", "function" },
    { "execute", "function" },
    { "fs.attributes", "function" }, { "fs.dir", "function" },
    { "fs.mkdir", "function" },      { "fs.rmdir", "function" },
    -- input / screens
    { "mouse.absolutePosition", "function" }, { "mouse.getCurrentScreen", "function" },
    { "screen.mainScreen", "function" },      { "screen.allScreens", "function" },
    { "keycodes.map", "table" },
    -- eventtap (event.types/properties are the constant maps mac indexes heavily)
    { "eventtap.new", "function" }, { "eventtap.event", "table" },
    { "eventtap.event.types", "table" }, { "eventtap.event.properties", "table" },
    { "eventtap.event.newKeyEvent", "function" },
    { "eventtap.event.newMouseEvent", "function" },
    -- apps / windows (get is mac's primary lookup; watcher/filter now real)
    { "application.get", "function" }, { "application.frontmostApplication", "function" },
    { "application.watcher", "table" }, { "application.watcher.new", "function" },
    { "window.focusedWindow", "function" }, { "window.find", "function" },
    { "window.filter", "table" }, { "window.filter.new", "function" },
    -- accessibility trees
    { "uielement.watcher", "table" }, { "uielement.focusedElement", "function" },
    { "axuielement.systemWideElement", "function" },
    { "axuielement.systemElementAtPosition", "function" },
    -- io / net / media
    { "http.asyncGet", "function" },
    { "task.new", "function" },
    { "audiodevice.defaultOutputDevice", "function" },
    { "audiodevice.findOutputByName", "function" },
    { "urlevent.openURL", "function" },
    { "sound.getByFile", "function" }, { "sound.getByName", "function" },
    { "pasteboard.setContents", "function" }, { "pasteboard.watcher", "callable" },
    { "distributednotifications.post", "function" },
    { "distributednotifications.new", "function" },
    -- ui surfaces (contract only -- do NOT instantiate; they show real UI)
    { "canvas.new", "function" }, { "canvas.windowLevels", "table" },
    { "canvas.windowBehaviors", "table" },
    { "menubar.new", "function" }, { "notify.new", "function" },
    { "dialog.chooseFileOrFolder", "function" }, { "dialog.blockAlert", "function" },
    { "geometry.rect", "function" },
    -- webview (opt-in on mudspoon via MUDSPOON_WEBVIEW=1; auto-skipped when stubbed)
    { "webview.new", "function" }, { "webview.usercontent.new", "function" },
    { "webview.windowMasks", "table" },
    -- host-provided fields / hooks
    { "configdir", "string" }, { "processInfo.processID", "number" },
    { "reload", "function" }, { "accessibilityState", "function" },
    { "openConsole", "function" }, { "loadSpoon", "function" },
    -- hs.focus: mudspoon-provided, no upstream hs extension. Left UNSCOPED on
    -- purpose so the Mac run settles empirically whether real HS resolves it.
    { "focus", "function" },
}

local function isStub(v)
    return type(v) == "table" and tostring(v):find("hs stub", 1, true) ~= nil
end

for _, c in ipairs(CONTRACT) do
    local path, ty, scope = c[1], c[2], c[3] or "both"
    local mod  = path:match("^[^.]+")
    local name = path:match("%.(.+)$") or "exists"
    test(mod, name, "contract", function()
        if scope ~= "both" and scope ~= HOST then
            skip("scoped to " .. scope .. " (host is " .. HOST .. ")")
        end
        if isStub(hs[mod]) then
            skip("module '" .. mod .. "' is a black-hole stub (opt-in / unbuilt on this host)")
        end
        local v, err = nav(path)
        if v == nil then fail(err) end
        local t = type(v)
        local ok = (ty == "callable") and (t == "function" or t == "table") or (t == ty)
        if not ok then fail("hs." .. path .. " is " .. t .. ", expected " .. ty) end
        return t
    end)
end

-- -----------------------------------------------------------------------------
-- BEHAVIOR: does it actually work? Headless-safe, side-effect-free (or restored).
-- -----------------------------------------------------------------------------

-- json round-trips a nested value (both hosts)
test("json", "roundtrip", "behavior", function()
    local src = { a = 1, b = "two", c = { d = true, e = { 1, 2, 3 } }, n = 3688748 }
    local enc = hs.json.encode(src, false)
    needType(enc, "string", "encode()")
    local dec = hs.json.decode(enc)
    need(deepEqual(src, dec), "decode(encode(x)) != x  (enc=" .. enc .. ")")
    return enc
end)

-- json canonical form: sorted keys, compact, integers w/o fraction.
-- mudspoon's pure-Lua json guarantees this; real Hammerspoon's C json does NOT
-- sort keys (the Mac registry path sorts via `jq -c -S`), so this is the exact
-- invariant the Windows registry-signature fix relies on -> scope to mudspoon.
test("json", "canonical-sorted", "behavior", function()
    if HOST ~= "mudspoon" then skip("HS json does not guarantee key order (jq sorts on Mac)") end
    local got = hs.json.encode({ b = 2, a = 1, n = 3688748, z = { y = 1, x = 2 } }, false)
    local want = '{"a":1,"b":2,"n":3688748,"z":{"x":2,"y":1}}'
    need(got == want, "canonical mismatch\n  want " .. want .. "\n  got  " .. tostring(got))
    return got
end)

-- geometry: rect center is the midpoint (point with x,y)
test("geometry", "center", "behavior", function()
    local r = hs.geometry.rect(0, 0, 100, 50)
    local c = r.center
    need(c ~= nil, "rect.center is nil")
    need(approx(c.x, 50) and approx(c.y, 25),
        "center = (" .. tostring(c.x) .. "," .. tostring(c.y) .. "), want (50,25)")
    return { x = c.x, y = c.y }
end)

-- execute: a POSIX echo round-trips through the shell (sh husk on Windows).
test("execute", "echo", "behavior", function()
    local out = hs.execute("echo smoketest_marker")
    out = tostring(out or ""):gsub("%s+$", "")
    need(out:find("smoketest_marker", 1, true) ~= nil,
        "echo did not round-trip (got '" .. out .. "')")
    return out
end)

-- fs: stat + list a temp file we create, then remove it.
test("fs", "stat-and-list", "behavior", function()
    local dir  = tmpBase()
    local fname = "mudspoon_smoke_" .. tostring(os.time()) .. "_" .. tostring(math.random(1e6)) .. ".txt"
    local path = dir .. "/" .. fname
    local fh = io.open(path, "w"); need(fh ~= nil, "could not create temp file at " .. path)
    fh:write("hello"); fh:close()
    local attr = hs.fs.attributes(path)
    need(type(attr) == "table", "fs.attributes returned " .. type(attr))
    need(attr.mode == "file", "attr.mode = " .. tostring(attr.mode) .. ", want 'file'")
    need(tonumber(attr.size) == 5, "attr.size = " .. tostring(attr.size) .. ", want 5")
    local seen = false
    for entry in hs.fs.dir(dir) do if entry == fname then seen = true break end end
    os.remove(path)
    need(seen, "fs.dir did not list the temp file")
    return attr.size
end)

-- pasteboard: set/get round-trip, ORIGINAL CONTENTS RESTORED.
test("pasteboard", "roundtrip", "behavior", function()
    if type(hs.pasteboard.getContents) ~= "function"
        or type(hs.pasteboard.setContents) ~= "function" then
        skip("pasteboard get/setContents unavailable")
    end
    local orig = hs.pasteboard.getContents()
    local mark = "mudspoon-smoke-" .. tostring(os.time())
    hs.pasteboard.setContents(mark)
    local got = hs.pasteboard.getContents()
    hs.pasteboard.setContents(orig or "")           -- restore
    need(got == mark, "pasteboard round-trip failed (got '" .. tostring(got) .. "')")
    return true
end)

-- application: frontmost app is queryable and names itself.
test("application", "frontmost-name", "behavior", function()
    local app = hs.application.frontmostApplication()
    if app == nil then skip("no frontmost application") end
    need(type(app.name) == "function", "app:name missing")
    local n = app:name()
    need(n == nil or type(n) == "string", "app:name() returned " .. type(n))
    return type(n) == "string" and "<string>" or "nil"
end)

-- screen: main screen reports a usable frame with numeric geometry.
test("screen", "main-frame", "behavior", function()
    local scr = hs.screen.mainScreen()
    if scr == nil then skip("no main screen") end
    local f = scr:frame()
    need(type(f) == "table", "frame() returned " .. type(f))
    for _, k in ipairs({ "x", "y", "w", "h" }) do
        need(type(f[k]) == "number", "frame." .. k .. " is " .. type(f[k]))
    end
    need(f.w > 0 and f.h > 0, "frame has non-positive size")
    return { w = f.w, h = f.h }
end)

-- window: a focused window (if any) reports a numeric frame.
test("window", "frame-shape", "behavior", function()
    local w = hs.window.focusedWindow()
    if w == nil then skip("no focused window") end
    local f = w:frame()
    need(type(f) == "table", "frame() returned " .. type(f))
    for _, k in ipairs({ "x", "y", "w", "h" }) do
        need(type(f[k]) == "number", "frame." .. k .. " is " .. type(f[k]))
    end
    return true
end)

-- audiodevice: default output device names itself.
test("audiodevice", "default-output", "behavior", function()
    local d = hs.audiodevice.defaultOutputDevice()
    if d == nil then skip("no default output device") end
    need(type(d.name) == "function", "device:name missing")
    local n = d:name()
    need(n == nil or type(n) == "string", "device:name() returned " .. type(n))
    return type(n) == "string" and "<string>" or "nil"
end)

-- -----------------------------------------------------------------------------
-- BEHAVIOR (async): needs the runloop.
-- -----------------------------------------------------------------------------

-- timer actually fires.
testAsync("timer", "doAfter-fires", function(done)
    local t0 = os.clock()
    hs.timer.doAfter(0.05, function()
        done("pass", nil, "fired")
    end)
end, 2.0)

-- pathwatcher: a file change under a watched dir invokes the callback.
testAsync("pathwatcher", "fires-on-change", function(done)
    if type(hs.pathwatcher) ~= "table" or type(hs.pathwatcher.new) ~= "function" then
        return done("skip", "hs.pathwatcher.new unavailable")
    end
    local dir = tmpBase() .. "/mudspoon_smoke_pw_" .. tostring(os.time()) .. "_" .. tostring(math.random(1e6))
    hs.fs.mkdir(dir)
    local fired = false
    local watcher
    watcher = hs.pathwatcher.new(dir, function()
        if fired then return end
        fired = true
        if watcher then watcher:stop() end
        done("pass", nil, "notified")
    end)
    if not watcher then return done("skip", "pathwatcher.new returned nil") end
    watcher:start()
    -- give the watcher a beat to arm, then touch a file inside it.
    hs.timer.doAfter(0.2, function()
        local fh = io.open(dir .. "/touch.txt", "w")
        if fh then fh:write("x"); fh:close() end
    end)
end, 3.0)

-- http (network-gated): a known raw URL returns HTTP 200 via async curl/NSURL.
testAsync("http", "asyncGet-200", function(done)
    if not WANT_NET then return done("skip", "network tests off (set MUDSPOON_SMOKE_NET=1)") end
    local url = "https://raw.githubusercontent.com/mudbourn/mudscript/main/registry/index.json"
    hs.http.asyncGet(url, nil, function(code)
        if code == 200 then done("pass", nil, 200)
        else done("fail", "HTTP " .. tostring(code)) end
    end)
end, 15.0)

-- -----------------------------------------------------------------------------
-- Report
-- -----------------------------------------------------------------------------
local function summarize()
    local s = { pass = 0, fail = 0, skip = 0, error = 0, timeout = 0, total = 0 }
    for _, r in ipairs(results) do
        s[r.status] = (s[r.status] or 0) + 1
        s.total = s.total + 1
    end
    return s
end

local function luaVersion()
    if type(jit) == "table" and jit.version then return jit.version end
    return _VERSION
end

local function writeReport()
    local summary = summarize()
    local report = {
        schema    = 1,
        host      = HOST,
        os        = IS_WINDOWS and "windows" or "posix",
        lua       = luaVersion(),
        network   = WANT_NET,
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        summary   = summary,
        tests     = results,
    }
    local outPath = os.getenv("MUDSPOON_SMOKE_OUT")
        or _G.MUDSPOON_SMOKE_OUT
        or ((hs.configdir or ".") .. "/smoke_report_" .. HOST .. ".json")
    local okEnc, body = pcall(hs.json.encode, report, true)
    if okEnc and body then
        local fh = io.open(outPath, "w")
        if fh then fh:write(body); fh:close() end
    end

    -- Console summary: every non-pass in full, then per-status totals.
    io.write("\n===== hs.* smoke report (" .. HOST .. " / " .. (IS_WINDOWS and "windows" or "posix") .. ") =====\n")
    for _, r in ipairs(results) do
        if r.status ~= "pass" and r.status ~= "skip" then
            io.write(string.format("  [%-7s] %-34s %s\n", r.status:upper(), r.id, r.detail or ""))
        end
    end
    local skips = {}
    for _, r in ipairs(results) do if r.status == "skip" then skips[#skips + 1] = r.id end end
    if #skips > 0 then io.write("  skipped: " .. table.concat(skips, ", ") .. "\n") end
    io.write(string.format("  totals: %d pass, %d fail, %d error, %d timeout, %d skip  (of %d)\n",
        summary.pass, summary.fail, summary.error, summary.timeout, summary.skip, summary.total))
    io.write("  report: " .. outPath .. "\n")
    io.write("=================================================================\n")
    if type(io.stdout) == "table" and io.stdout.flush then io.stdout:flush() end
end

local function exitCode()
    local s = summarize()
    return (s.fail + s.error + s.timeout > 0) and 1 or 0
end

-- real maybeFinalize (referenced by testAsync above)
maybeFinalize = function()
    if finalized or pending > 0 then return end
    finalized = true
    writeReport()
    if DRIVE_RUNLOOP then
        -- stop pumping and end the process with a meaningful code.
        hs.timer.doAfter(0.05, function() os.exit(exitCode()) end)
    end
end

-- -----------------------------------------------------------------------------
-- Drive to completion.
-- -----------------------------------------------------------------------------
if pending == 0 then
    writeReport()
    return exitCode()          -- Windows hook exits with this; Mac CLI returns.
elseif DRIVE_RUNLOOP then
    -- mudspoon: pump the foundation runloop; maybeFinalize() os.exit()s when done.
    hs.run()
    return exitCode()          -- normally unreachable (os.exit fires first)
else
    -- Hammerspoon: the app runloop is already live. Async records land later and
    -- maybeFinalize() writes the report then. The launcher polls for the file.
    return exitCode()
end
