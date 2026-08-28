#!/usr/bin/env bash
# =============================================================================
# smoke_mac.sh -- run the hs.* smoke suite inside a RUNNING Hammerspoon on macOS.
#
#   bash test/smoke_mac.sh            # core suite
#   bash test/smoke_mac.sh --net      # include network tests
#
# Uses Hammerspoon's command-line tool `hs`, which evaluates Lua inside the live
# Hammerspoon process (so the suite runs against the real hs.* API, on the app's
# runloop -- required for the async tests). Because `hs` runs in Hammerspoon's own
# process, options are injected as GLOBALS, not shell env, and the report is
# written to ~/.hammerspoon/smoke_report_hammerspoon.json.
#
# Prereqs: Hammerspoon running, with the command-line tool installed
#   (Hammerspoon menu -> Preferences -> "Install command line tool"), which needs
#   `hs.ipc` loaded in your init.lua (`require("hs.ipc")`).
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMOKE="$HERE/smoke.lua"
OUT="$HOME/.hammerspoon/smoke_report_hammerspoon.json"

WANT_NET=false
[ "${1:-}" = "--net" ] && WANT_NET=true

if ! command -v hs >/dev/null 2>&1; then
    echo "FAIL: the 'hs' command-line tool is not on PATH."
    echo "      In Hammerspoon: Preferences -> 'Install command line tool',"
    echo "      and ensure your init.lua does require('hs.ipc')."
    exit 2
fi
[ -f "$SMOKE" ] || { echo "FAIL: smoke.lua not found at $SMOKE"; exit 2; }

# Build the in-process Lua: set option globals, then dofile the suite.
PRE=""
$WANT_NET && PRE="MUDSPOON_SMOKE_NET=true; "
LUA="${PRE}dofile('${SMOKE}')"

rm -f "$OUT"
echo "-> running smoke suite inside Hammerspoon ..."
hs -c "$LUA" >/dev/null 2>&1 || true    # the suite's own report is the result, not hs -c's rc

# The suite writes the report only after its async tests settle on the runloop,
# so poll for the fresh file (network tests need longer).
WAIT=12; $WANT_NET && WAIT=30
DEADLINE=$(( $(date +%s) + WAIT ))
while [ ! -f "$OUT" ] && [ "$(date +%s)" -lt "$DEADLINE" ]; do sleep 0.3; done

if [ ! -f "$OUT" ]; then
    echo "FAIL: no report at $OUT -- is Hammerspoon running with hs.ipc loaded?"
    exit 2
fi

echo "-> report: $OUT"
if command -v jq >/dev/null 2>&1; then
    jq -r '.summary | "   totals: \(.pass) pass, \(.fail) fail, \(.error) error, \(.timeout) timeout, \(.skip) skip (of \(.total))"' "$OUT"
    jq -r '.tests[] | select(.status != "pass" and .status != "skip") | "   [\(.status | ascii_upcase)] \(.id)  \(.detail // "")"' "$OUT"
fi
echo
echo "Next: copy this report next to the Windows one and diff them:"
echo "   luajit test/diff_smoke.lua $OUT smoke_report_mudspoon.json"
