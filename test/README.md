# hs.* smoke & parity suite

A single test suite that runs **unchanged** under real Hammerspoon (macOS) and
mudspoon (Windows), then a differ that separates real **parity gaps** from
platform-inherent noise. The point is to stop running the port blind: capture a
report on each host and diff them, so a divergence is *measured*, not guessed.

## Files

| File | Runs on | What it is |
|------|---------|------------|
| `smoke.lua` | both | The suite. Assumes a global `hs`. Contract + behavior + async tests over the exact hs.* surface mudscript uses. Writes a JSON report + console summary. |
| `smoke_win.ps1` | Windows | Boots `run_mudscript.lua` with `MUDSPOON_SMOKE` set and runs the suite against the real port. |
| `smoke_mac.sh` | macOS | Runs the suite inside a live Hammerspoon via the `hs` command-line tool. |
| `diff_smoke.lua` | anywhere w/ luajit | Compares two reports; prints PARITY GAPS / VALUE SKEW / COVERAGE / INFO. |

## Run it

**Windows (mudspoon):**
```
pwsh -File test\smoke_win.ps1            # core suite  -> smoke_report_mudspoon.json
pwsh -File test\smoke_win.ps1 -Net       # + network tests
pwsh -File test\smoke_win.ps1 -Webview   # + real WebView2 bring-up
```

**macOS (Hammerspoon)** — needs the `hs` CLI (Preferences → *Install command line
tool*) and `require("hs.ipc")` in your `init.lua`:
```
bash test/smoke_mac.sh                   # -> ~/.hammerspoon/smoke_report_hammerspoon.json
bash test/smoke_mac.sh --net
```

**Diff the two:**
```
luajit test/diff_smoke.lua smoke_report_hammerspoon.json smoke_report_mudspoon.json
```
Exit code is `1` if any PARITY GAP is found. Only `PARITY GAPS` are actionable —
a test that **passes on one host and is tested-and-broken on the other**. The other
buckets are noise you can usually ignore:
- **VALUE SKEW** — both pass but observed values differ (e.g. a different monitor
  size). Expected.
- **COVERAGE** — a test appears in one report only (version drift between the two
  `smoke.lua` copies). Re-sync the file.
- **INFO** — pass vs `skip`: the module wasn't *evaluated* on one side (opt-in
  webview, no focused window, a scoped test). Not a gap.

## What it checks

- **Contract** — presence + type of every `hs.a.b` symbol mudscript actually calls.
  The list in `smoke.lua` is grep-derived from `mudscript/mac`, not guessed; an
  unused symbol would show up as a false gap. Regenerate the surface with:
  ```
  grep -rhoE "hs\.[a-zA-Z]+(\.[a-zA-Z]+){1,2}" mudscript/mac --include=*.lua | sort -u
  ```
- **Behavior** (headless-safe, side effects restored) — json round-trip and
  canonical form, geometry math, `hs.execute` echo, `hs.fs` stat/list, pasteboard
  round-trip (original restored), frontmost app / main screen / focused window
  shape, default audio device.
- **Async** (needs the runloop) — a timer fires, a `pathwatcher` sees a file
  change, and (with `--net`/`-Net`) `http.asyncGet` returns 200.

UI-showing surfaces (alert, menubar, notify, canvas, webview, dialog) are
**contract-only** — the suite never instantiates them, so it won't spray windows.

## Known, expected results

- `json.canonical-sorted` is **mudspoon-only**. mudspoon's pure-Lua `hs.json`
  sorts keys; real Hammerspoon's C json does not (the Mac registry path sorts via
  `jq -c -S`). This is the exact invariant the Windows registry-signature fix
  relies on, so the suite guards it — it shows as INFO in the diff, not a gap.
- `distributednotifications.{post,new}` currently **fail on mudspoon** (unimplemented)
  and pass on Hammerspoon. mudscript guards the feature with
  `if not hs.distributednotifications then return end` ([ms_core.lua:6632]), so it
  degrades gracefully — a real but low-priority, non-blocking gap.
- `hs.focus` is tested **unscoped on purpose**. It is mudspoon-provided with no
  upstream hs extension; the first Mac run settles empirically whether real
  Hammerspoon resolves it (expected: it does not). Read that result rather than
  assuming.
- `webview.*` is skipped on Windows unless you pass `-Webview` (it is an opt-in
  black-hole stub by default), so it shows as INFO, not a gap.

## How it hooks in

On Windows, `run_mudscript.lua` checks `MUDSPOON_SMOKE`: if set, it runs that file
against the fully-assembled `hs` (all `realExtra` modules + host fields wired) and
exits **without** loading mudscript's `init.lua`/UI. The suite drives its own
foundation runloop for the async tests and exits `0` (all pass) / `1` (any failure);
a load or runtime error in the suite exits `2`.

On macOS there is no `run_mudscript.lua`; `smoke_mac.sh` injects the suite into the
already-running Hammerspoon with `hs -c "dofile(...)"`. Because that evaluates in
Hammerspoon's own process (shell env invisible), options are passed as globals
(`MUDSPOON_SMOKE_NET=true`) and the report lands at
`~/.hammerspoon/smoke_report_hammerspoon.json`.
