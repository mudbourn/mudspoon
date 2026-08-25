-- mudspoon hs.webview end-to-end spike (WebView2 over LuaJIT COM) --
    -- The artifact that PROVES the WebView2 binding on the Windows rig. It exercises
    -- the whole path mudscript depends on, in order:
    --
    --   1. build a user-content controller and a webview over foundation's runloop
    --   2. load an HTML string that, on load, posts a message back via
    --      window.chrome.webview.postMessage(...)                         (JS -> Lua)
    --   3. receive that message in the controller's setCallback              (bridge)
    --   4. push JS INTO the page with evaluateJavaScript, which posts again  (Lua -> JS -> Lua)
    --   5. close the view cleanly and tear the runloop down
    --
    -- This is the WebView2 analog of spike_hook_loop_alert.lua / smoke_alert_combined.lua:
    -- a SEE-IT + ASSERT-IT run. The pass is (a) your eyes seeing a small web panel appear,
    -- and (b) the script confirming BOTH bridge messages arrived and teardown was clean.
    -- A watchdog fails loud if bring-up wedges (e.g. WebView2 runtime missing).
    --
    -- ============================ UNVERIFIED ============================
    -- hs.webview is a parse-checked-only scaffold. This spike has NEVER run.
    -- Requires: a physical Windows console (NOT RDP -- layered top-most windows
    -- misbehave over RDP), the Edge WebView2 Evergreen runtime installed, and
    -- WebView2Loader.dll on the DLL search path next to luajit.exe.
    --
    --   luajit spike_webview.lua
    -- ===================================================================
-- END --

-- Resolve requires from this script's own directory (matches smoke_alert_combined.lua). --
    local here = (arg[0] or "spike_webview.lua"):gsub("[^/\\]*$", "")
    if here == "" then here = "./" end
    package.path = here .. "?.lua;" .. here .. "?/init.lua;" .. package.path
-- END --

local host    = require("hs.foundation")
local timer   = require("hs.timer")
local webview = require("hs.webview")   -- not on the frozen hs namespace; required directly

print("[spike_webview] starting WebView2 bring-up...")

-- Track what the bridge delivers so we can assert at the end. --
    local got = { load = false, injected = false }
    local errored = false

    local function guard(label, fn)
        local ok, err = pcall(fn)
        if not ok then
            errored = true
            io.stderr:write("[spike_webview] FAIL (" .. label .. "): " .. tostring(err) .. "\n")
        end
    end
-- END --

-- 1 + 3: controller with the JS -> Lua callback. --
    local ucc = webview.usercontent.new("mudspoon")
    ucc:setCallback(function(message)
        print("[spike_webview] page -> Lua: " .. tostring(message))
        if message == "loaded" then
            got.load = true
        elseif message == "injected" then
            got.injected = true
        end
    end)
-- END --

-- 1: the webview. Small centred-ish panel on the primary display. --
    local view
    guard("new", function()
        view = webview.new({ x = 200, y = 200, w = 480, h = 320 }, {}, ucc)
        view:show()
    end)
-- END --

-- 2: HTML that posts "loaded" as soon as it runs. The page speaks the WebView2
--     API (window.chrome.webview.postMessage) exactly as mudscript's pages do.
    local PAGE = [[
<!doctype html><html><head><meta charset="utf-8"></head>
<body style="background:#1c1f24;color:#e8e8e8;font-family:sans-serif;padding:24px">
  <h2>mudspoon webview spike</h2>
  <p id="s">waiting...</p>
  <script>
    function post(s){ window.chrome.webview.postMessage(s); }
    // Announce that the page loaded.
    post("loaded");
    // A hook the Lua side calls into via evaluateJavaScript.
    window.mudspoonPing = function(){ document.getElementById('s').textContent = 'pinged'; post("injected"); };
  </script>
</body></html>
]]

    guard("html", function()
        view:html(PAGE)  -- queued if the core is not ready yet; flushed on ready
    end)
-- END --

-- 4: once the page has had time to load + post "loaded", push JS in that makes the
--     page post "injected" back. Proves Lua -> JS -> Lua round trips.
    timer.doAfter(2.0, function()
        guard("evaluateJavaScript", function()
            view:evaluateJavaScript("window.mudspoonPing && window.mudspoonPing();")
        end)
        print("[spike_webview] evaluateJavaScript fired")
    end)
-- END --

-- 5: close the view cleanly. --
    timer.doAfter(4.0, function()
        guard("delete", function() view:delete() end)
        print("[spike_webview] view deleted")
    end)
-- END --

-- Finish: report + tear the runloop down. --
    timer.doAfter(5.0, function()
        print("[spike_webview] sequence complete; shutting down.")
        host.shutdown()
    end)
-- END --

-- Watchdog: never wedge the console if bring-up stalls (e.g. no WebView2 runtime). --
    timer.doAfter(12, function()
        io.stderr:write("[spike_webview] TIMEOUT: run did not complete in 12s.\n")
        host.shutdown()
    end)
-- END --

host.run()

-- Verdict. --
    if errored then
        io.stderr:write("[spike_webview] INCOMPLETE: a Lua/FFI/COM error occurred above.\n")
        os.exit(1)
    end
    if not got.load then
        io.stderr:write("[spike_webview] FAIL: never received the page 'loaded' message.\n")
        os.exit(1)
    end
    if not got.injected then
        io.stderr:write("[spike_webview] FAIL: evaluateJavaScript round-trip ('injected') not seen.\n")
        os.exit(1)
    end
    print("[spike_webview] PASS: window shown, HTML loaded, JS<->Lua bridge both ways, clean teardown.")
    os.exit(0)
-- END --
