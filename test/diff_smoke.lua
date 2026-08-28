-- =============================================================================
-- diff_smoke.lua -- compare two smoke.lua reports to separate real PARITY GAPS
-- from platform-inherent / environmental differences.
--
--   luajit test/diff_smoke.lua <reportA.json> <reportB.json>
--
-- Typically A = the Mac (Hammerspoon) report, B = the Windows (mudspoon) report,
-- but order does not matter -- findings name each host. Runs in plain LuaJIT; it
-- reuses the port's own pure-Lua JSON decoder (../hs/json.lua), overridable with
-- MUDSPOON_JSON=<path>. Exit code 1 if any GAP is found, else 0.
-- =============================================================================

local function scriptDir()
    local p = (arg[0] or ""):gsub("[^/\\]*$", "")
    return (p == "") and "./" or p
end

local jsonPath = os.getenv("MUDSPOON_JSON") or (scriptDir() .. "../hs/json.lua")
local ok, json = pcall(dofile, jsonPath)
if not ok or type(json) ~= "table" then
    io.stderr:write("diff_smoke: could not load JSON decoder at " .. jsonPath ..
        "\n  set MUDSPOON_JSON to the path of mudspoon's hs/json.lua\n")
    os.exit(2)
end

local function readReport(path)
    local fh = io.open(path, "r")
    if not fh then io.stderr:write("diff_smoke: cannot open " .. tostring(path) .. "\n"); os.exit(2) end
    local body = fh:read("*a"); fh:close()
    local okD, doc = pcall(json.decode, body)
    if not okD or type(doc) ~= "table" then
        io.stderr:write("diff_smoke: " .. path .. " is not a readable report\n"); os.exit(2)
    end
    return doc
end

local pathA, pathB = arg[1], arg[2]
if not (pathA and pathB) then
    io.stderr:write("usage: luajit test/diff_smoke.lua <reportA.json> <reportB.json>\n")
    os.exit(2)
end

local A, B = readReport(pathA), readReport(pathB)
local nameA = A.host or "A"
local nameB = B.host or "B"
if nameA == nameB then nameA, nameB = nameA .. "#1", nameB .. "#2" end

local function index(doc)
    local m = {}
    for _, t in ipairs(doc.tests or {}) do m[t.id] = t end
    return m
end
local IA, IB = index(A), index(B)

-- A hard-negative is a status that means "tested and broken". skip means "not
-- evaluated here" (opt-in module, no window/device) -- environmental, not a gap.
local HARDNEG = { fail = true, error = true, timeout = true }
local function working(s) return s == "pass" end
local function obsStr(v)
    if v == nil then return "nil" end
    if type(v) ~= "table" then return tostring(v) end
    local parts = {}
    for k, val in pairs(v) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(val) end
    table.sort(parts)
    return "{" .. table.concat(parts, ",") .. "}"
end

local gaps, skews, coverage, info = {}, {}, {}, {}

-- union of ids, stable order = A's order then B-only
local seen, order = {}, {}
for _, t in ipairs(A.tests or {}) do if not seen[t.id] then seen[t.id] = true; order[#order + 1] = t.id end end
for _, t in ipairs(B.tests or {}) do if not seen[t.id] then seen[t.id] = true; order[#order + 1] = t.id end end

for _, id in ipairs(order) do
    local a, b = IA[id], IB[id]
    if not a or not b then
        coverage[#coverage + 1] = string.format("%-38s present in %s only",
            id, a and nameA or nameB)
    elseif (working(a.status) and HARDNEG[b.status])
        or (working(b.status) and HARDNEG[a.status]) then
        -- one host passes, the other is tested-and-broken -> the actionable gap
        gaps[#gaps + 1] = string.format("%-38s %s=%s   %s=%s   (%s)",
            id, nameA, a.status, nameB, b.status,
            (HARDNEG[a.status] and a.detail or b.detail or ""))
    elseif a.status == b.status and a.status == "skip" then
        -- both skipped: environmental on both, nothing to see
    elseif working(a.status) and working(b.status)
        and a.observed ~= nil and b.observed ~= nil
        and obsStr(a.observed) ~= obsStr(b.observed) then
        skews[#skews + 1] = string.format("%-38s %s=%s   %s=%s",
            id, nameA, obsStr(a.observed), nameB, obsStr(b.observed))
    elseif a.status ~= b.status then
        -- pass vs skip, skip vs fail, ... -> not evaluated on one side; not a gap
        info[#info + 1] = string.format("%-38s %s=%s   %s=%s",
            id, nameA, a.status, nameB, b.status)
    end
end

local function section(title, list)
    io.write("\n" .. title .. " (" .. #list .. ")\n")
    if #list == 0 then io.write("  (none)\n") return end
    for _, line in ipairs(list) do io.write("  " .. line .. "\n") end
end

io.write("================ smoke diff ================\n")
io.write(string.format("  %s: %s / lua=%s / %d tests / %s\n",
    nameA, A.os or "?", tostring(A.lua), #(A.tests or {}), A.timestamp or "?"))
io.write(string.format("  %s: %s / lua=%s / %d tests / %s\n",
    nameB, B.os or "?", tostring(B.lua), #(B.tests or {}), B.timestamp or "?"))

section("PARITY GAPS  (works on one host, not the other)", gaps)
section("VALUE SKEW   (both pass, observed differs)", skews)
section("COVERAGE     (test present in one report only)", coverage)
section("INFO         (pass vs skip -- environmental, not a gap)", info)

io.write("\n")
os.exit(#gaps > 0 and 1 or 0)
