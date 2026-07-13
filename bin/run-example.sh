#!/usr/bin/env bash
# run-example.sh — the runnable free-content multiplayer example for the headless MP rig.
#
# WHAT IT PROVES (all on OpenMW's freely-licensed example-suite content — no Morrowind/commercial
# data): two real TES3MP clients, each its own display + isolated profile, join ONE dedicated server
# in ONE world and SEE EACH OTHER. Every assertion is backed by a real server/client log line; the
# PASS/FAIL gate is deterministic (log-gated). An optional STATIC screenshot compare runs if a
# reference has been blessed.
#
# WHY A FIXTURE (not fresh chargen): example-suite's template.omwgame ships NO class or birthsign
# records, so TES3MP character generation can never complete (empty class list -> OK disabled; empty
# birthsign list -> OK disabled). The scenario therefore RESUMES two pre-authored returning players
# (scenarios/example/player/{a,b}.json, password "a"), which is also the rig's recommended
# deterministic path. See scenarios/example/README.md for how the fixture was authored and its quirks
# (the world is entirely underwater -> the players carry a permanent water-breathing effect so they
# rest on the seafloor without drowning; that is what makes the run deterministic).
#
# Usage:   bin/run-example.sh                 # run + assert (green exit 0 / red non-zero)
#          UPDATE_REFS=1 bin/run-example.sh   # re-bless the server-log signature (+ screenshot) — human decision
# A full run takes a few minutes on software GL; run it directly (or under your CI's long-job runner).
set -uo pipefail
DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
REPO=$(cd "$DIR/.." && pwd)
source "$REPO/lib/rig.sh"

EX=$REPO/scenarios/example
CLILOG_A=/tmp/mp-rig-example-a.log
CLILOG_B=/tmp/mp-rig-example-b.log
rm -f "$CLILOG_A" "$CLILOG_B"

# Reference sets live under the scenario dir. These MUST be exported BEFORE sourcing logcheck.sh /
# compare.sh, which read them (LOG_REF_DIR, LOG_MARKERS, REF_DIR, MANIFEST) at source time.
export RIG_LOG_REF_DIR=$EX/reference-logs
export RIG_REF_DIR=$EX/reference-images
export RIG_REF_MANIFEST=$EX/reference-images/manifest.tsv
# Narrow, deterministic server-log signature vocabulary for THIS scenario (+ error tripwires that
# must stay ABSENT). Excludes volatile noise (master-server retries, world-time ticks, the
# neighbour-cell authority spam, the DedicatedPlayer position stream).
export RIG_LOG_MARKERS='was allowed to connect|Creating new player|example-suite-compat|Authority of cell 0, -7 is now a|script error|Server crash from script error|bad argument|luabridge'

# shellcheck source=../lib/logcheck.sh
source "$REPO/lib/logcheck.sh"
source "$REPO/lib/compare.sh"
trap rig_cleanup EXIT

# cshot <display> <name> <crop-geom> — capture a display, crop to a region, echo the cropped PNG path.
# Used for the STATIC blessed frame: crop to a stable GUI region (the KB-19 / VERIFICATION convention).
cshot() { local d=$1 n=$2 geom=$3; local out=$RIG_SHOTDIR/$n.png
          mkdir -p "$RIG_SHOTDIR"
          DISPLAY="$d" import -window root "$out" 2>/dev/null
          magick "$out" -crop "$geom" +repage "$out" 2>/dev/null
          printf '%s\t%s\n' "$n" "$(date +%s.%N)" >> "$RIG_SHOTDIR/captures.tsv"
          echo "$out"; }

# ---- 1. Build a throwaway CoreScripts work-copy with the example-suite compat overlay ------------
# The shared CoreScripts clone is never modified (all writes stay inside headless-mp-rig). The
# overlay's compat shim keeps stock CoreScripts from crashing on non-Morrowind content.
SHARED_CS=$RIG_CORESCRIPTS
WORK_CS=/tmp/mp-rig-example-cs
rm -rf "$WORK_CS"; mkdir -p "$WORK_CS/data"
cp -a "$SHARED_CS/scripts" "$SHARED_CS/lib" "$WORK_CS/"
for s in $RIG_STATE_SUBDIRS; do mkdir -p "$WORK_CS/data/$s"; done
cp "$SHARED_CS/data/banlist.json" "$WORK_CS/data/" 2>/dev/null || echo '[]' > "$WORK_CS/data/banlist.json"
cp "$EX/coreScripts-overlay/scripts/custom/example-suite-compat.lua" "$WORK_CS/scripts/custom/"
cp "$EX/coreScripts-overlay/scripts/customScripts.lua" "$WORK_CS/scripts/"
export RIG_CORESCRIPTS="$WORK_CS"
export RIG_SETTINGS_SRC="$EX/settings.cfg"    # [Models] remap so the client finds BasicPlayer.dae

# ---- 2. Content + fixture -----------------------------------------------------------------------
rig_check_prereqs
rig_require_clean
rig_set_server_home
rig_set_required_datafiles template.omwgame          # prepends builtin.omwscripts (client entry 0)
rig_add_content example "data=$EXAMPLE_SUITE" "content=template.omwgame"
rig_load_scenario "$EX"                              # restores player/a.json + player/b.json fresh

# ---- 3. Boot server + two clients ----------------------------------------------------------------
rig_make_profile
rig_start_xvfb
rig_start_xvfb2
rig_start_server
rig_start_client  "$CLILOG_A"    # a on :99
rig_start_client2 "$CLILOG_B"    # b on :100
rig_note "both clients booting to the login screen..."
rig_wait_event "$CLILOG_A" 'ID_CONNECTION_REQUESTED_ACCEPTED' 40 1 || true
rig_wait_event "$CLILOG_B" 'ID_CONNECTION_REQUESTED_ACCEPTED' 40 1 || true
sleep "$RIG_WORLD_LOAD"          # llvmpipe world load -> name box on both

# ---- 4. Returning-login both + SCREENSHOTS demonstrating both compare modes ----------------------
# This scenario doubles as the worked example of the two screenshot signal types (docs/VERIFICATION.md):
#   * a DYNAMIC pair on a's display — one frame BEFORE b logs in, one AFTER; they MUST differ (b's
#     avatar appears in a's view). The gate is "motion present", robust to run-to-run non-determinism.
#   * a STATIC blessed frame on b's display — b's minimap cropped to a stable region; it must MATCH a
#     blessed reference within tolerance (crop-to-stable-GUI-region, the KB-19 convention).
rig_note "returning-login a (:99) first for cell authority..."
rig_login "$RIG_DISPLAY"  a a 0 "$CLILOG_A"
rig_start_idle_wiggler                                          # suppress the vanity camera on both displays
rig_wait_stable "$RIG_DISPLAY" FULL 12 0.7 0.012 - >/dev/null 2>&1 || true   # let a's world finish rendering
SHOT_A0=$(capture "$RIG_DISPLAY" 10-a-before-b "$RIG_SHOTDIR")  # DYNAMIC t0 — a alone in the world
rig_note "returning-login b (:100)..."
rig_login "$RIG_DISPLAY2" b a 0 "$CLILOG_B"
sleep 8                                                         # mutual DedicatedPlayer sync settles
SHOT_A1=$(capture "$RIG_DISPLAY" 11-a-after-b "$RIG_SHOTDIR")   # DYNAMIC t1 — b now visible in a's view
SHOT_B=$(cshot "$RIG_DISPLAY2" 20-b-minimap "${CROP_MINIMAP:-88x84+950+576}")  # STATIC — b's minimap, both markers

# ---- 5. Assertions — every one backed by a real log line (deterministic PASS/FAIL gate) ----------
SRV=$(rig_server_log)
FAILS=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAILS=$((FAILS+1)); }
# gate <log> <regex> <desc> [cap]  — poll (server stdout is block-buffered; never single-grep)
gate() { local log=$1 re=$2 desc=$3 cap=${4:-20}
         if rig_wait_event "$log" "$re" "$cap" 0.5; then pass "$desc"; else fail "$desc (no '/$re/')"; fi; }
# count_at_least <log> <fixed-string> <n> <desc>
count_at_least() { local log=$1 s=$2 n=$3 desc=$4 c
                   c=$(grep -cF "$s" "$log" 2>/dev/null || echo 0)
                   if [ "$c" -ge "$n" ]; then pass "$desc ($c>=$n)"; else fail "$desc ($c<$n)"; fi; }
# absent <log> <regex> <desc>
absent() { local log=$1 re=$2 desc=$3
           if grep -qiE "$re" "$log" 2>/dev/null; then fail "$desc (found /$re/)"; else pass "$desc"; fi; }

echo "============ ASSERTIONS ============"
# -- server: both clients admitted + created, compat shim fired, a owns the shared cell --
count_at_least "$SRV" "Client was allowed to connect" 2 "server admitted both clients"
count_at_least "$SRV" "Creating new player"           2 "server created both players"
gate "$SRV" 'example-suite-compat] filled'  "example-suite compat shim ran (no Morrowind assumption crash)"
gate "$SRV" 'Authority of cell 0, -7 is now a' "a holds authority of the shared cell 0, -7"
# -- cross-client mutual visibility (the bug class this rig exists to catch) --
gate "$CLILOG_A" 'b \([0-9]+\) has joined the server' "client a is told b joined"
gate "$CLILOG_A" 'DedicatedPlayer b'                  "client a sees b as a DedicatedPlayer"
gate "$CLILOG_B" 'DedicatedPlayer a'                  "client b sees a as a DedicatedPlayer"
# -- health/stability: neither player drowned (water-breathing fixture holds), no server error --
absent "$CLILOG_A" 'committed suicide' "player a did not drown"
absent "$CLILOG_B" 'committed suicide' "player b did not drown"
absent "$SRV" 'script error|Server crash from script error|bad argument|luabridge' "no server script error"

# ---- 6. Blessed server-log signature (regression tripwire; REVIEW-not-fail unless UPDATE_REFS) ----
echo "============ LOG SIGNATURE ============"
if [ "${UPDATE_REFS:-0}" = 1 ]; then
    promote_log example-server "$SRV"
    pass "server-log signature (re-)blessed"
else
    if check_log example-server "$SRV"; then pass "server-log signature matches blessed"
    else fail "server-log signature differs (see the diff above) — investigate or UPDATE_REFS=1 to re-bless"; fi
fi

# ---- 7. Screenshot signals — DYNAMIC pair (must DIFFER) + STATIC frame (must MATCH) ---------------
echo "============ SCREENSHOTS ============"
# DYNAMIC pair: a's view before vs after b appears. Gate motion PRESENT (RMSE >= floor) — the inverse
# of a static compare. A frozen/absent b (the sync bug) would leave the frames ~identical and fail.
DYN=$(magick compare -metric RMSE "$SHOT_A0" "$SHOT_A1" null: 2>&1 | grep -oE '\([0-9.eE+-]+\)' | head -1 | tr -d '()')
DYN_FLOOR=${DYN_FLOOR:-0.020}
echo "  DYNAMIC pair 10-a-before-b vs 11-a-after-b: RMSE=$DYN (floor $DYN_FLOOR)"
if [ -n "$DYN" ] && awk -v v="$DYN" -v t="$DYN_FLOOR" 'BEGIN{exit !(v+0>=t+0)}'; then
    pass "DYNAMIC pair differs — b appeared in a's view (motion present)"
else
    fail "DYNAMIC pair too similar (RMSE=$DYN < $DYN_FLOOR) — b did not visibly appear to a"
fi
# STATIC frame: b's minimap crop must match the blessed reference within its manifest tolerance.
if [ "${UPDATE_REFS:-0}" = 1 ]; then
    if promote_shot 20-b-minimap "$SHOT_B"; then pass "STATIC reference (re-)blessed"; else fail "STATIC bless failed (candidate '$SHOT_B')"; fi
elif [ -f "$RIG_REF_DIR/20-b-minimap.png" ]; then
    if compare_shot 20-b-minimap "$SHOT_B"; then pass "STATIC frame within tolerance"
    else fail "STATIC frame regression (see diff — real change, or re-bless with UPDATE_REFS=1)"; fi
else
    echo "  (no STATIC reference blessed yet — run UPDATE_REFS=1 to bless; candidate $SHOT_B)"
fi

echo "===================================="
if [ "$FAILS" -eq 0 ]; then echo "RESULT: GREEN — example scenario passed ($SRV)"; exit 0
else echo "RESULT: RED — $FAILS assertion(s) failed"; exit 1; fi
