#!/usr/bin/env bash
# repro-template.sh — skeleton for a TARGETED feature/bug repro (see docs/FEATURE-TESTS.md).
#
# The method: place a specific condition SERVER-SIDE via a one-off server-script hook, drive a real
# client at it, and assert the outcome FROM THE LOGS (deterministic) — not from a screenshot. Use
# this when a single feature or bug needs a deterministic headless reproduction. It's a regression
# guard, not a pass/fail visual gate. One repro per feature; name it for the feature.
#
# Copy this file to your-repro.sh and fill in the four TODO blocks. It reuses the shared rig
# (lib/rig.sh), so the headless gotchas (warp mouse, invisible-UI workaround, isolated profiles,
# stale-proc guards, event-gated waits, screenshots) all come for free.
set -uo pipefail
DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
# shellcheck source=../lib/rig.sh
source "$DIR/../lib/rig.sh"
trap rig_cleanup EXIT

PLAYER_NAME=${PLAYER_NAME:-ReproTester}
rig_run_dir "$(basename "${0%.sh}")" >/dev/null     # this run's dir under $RIG_RUNS
CLILOG=$RIG_RUN_DIR/client.log

# TODO 1 — server-side condition. Install a custom server-script hook that sets up the exact state
#   the feature needs. The robust pattern (see the combat/summon/spell-effect examples in
#   docs/FEATURE-TESTS.md): a one-off chat command that MODIFIES THE CALLER server-side
#   (max/adjust skills, attributes, health; grant a scroll + quick-key; spawn an actor) via the
#   CoreScripts API, so the blessed fixture stays untouched and rig_load_scenario clears what the run
#   saves. Put the hook in an overlay dir next to this script — overlay/scripts/custom/my-hook.lua plus
#   overlay/scripts/customScripts.lua.append holding `require("custom/my-hook")` — and pass it to
#   rig_corescripts_overlay below; your CoreScripts clone is never edited. Rig artifact to remember: a headless
#   client that never sends ID_PLAYER_CELL_STATE leaves the server's LoadedCells empty, so
#   CLIENT_GAMEPLAY object packets are rejected ("impossible packetOrigin for unloaded <cell>") —
#   force a LoadCell around any server-side object placement.
#
# TODO 2 — fresh state. Either load a blessed fixture (rig_load_scenario "$FIXTURE") or remove this
#   player's server-side json so the run is deterministic and the returning-player password dialog
#   doesn't stall login:
#   rm -f "$RIG_CORESCRIPTS"/data/player/"$PLAYER_NAME".json   (after rig_corescripts_overlay: the work copy)

rig_corescripts_overlay "$RIG_RUN_DIR/corescripts"   # add "$DIR/overlay" once TODO 1 has a hook
rig_check_prereqs
rig_require_clean
rig_set_server_home
# Content: a profile from rig.conf (RIG_CONTENT_<name>_DATA/_ARCHIVES/_FILES) — free example-suite
# (example) or real game data (e.g. mw). See docs/WRITING-SCENARIOS.md §4 "Content profiles".
rig_use_content "${CONTENT:-example}"

rig_make_profile
rig_start_xvfb
rig_start_server
rig_start_client "$CLILOG"                       # single client on $RIG_DISPLAY
rig_login "$RIG_DISPLAY" "$PLAYER_NAME" "${PLAYER_PASS:-test}" 1 "$CLILOG"
rig_start_idle_wiggler                            # suppress the vanity camera for the whole run

# TODO 3 — drive the client at the condition. Input/capture helpers take the target DISPLAY first
#   (single client => "$RIG_DISPLAY"): rig_key / rig_type / rig_tap / rig_click / rig_look to
#   move/aim/act, rig_chat_command to trigger a server hook, capture "$RIG_DISPLAY" <name> for a shot.
#   Prefer rig_wait_event on a server-log line over a blind sleep. Don't tighten the caps.
#   e.g.  rig_chat_command "$RIG_DISPLAY" "/combatprep"
#         rig_key "$RIG_DISPLAY" F                 # draw weapon
#         xdotool mousedown 1; sleep 0.7; xdotool mouseup 1   # swing (KB-1-synthetic-left-click-cast)

# TODO 4 — VERDICT from the logs. Poll (never single-grep — the server's captured stdout is
#   block-buffered) both logs for the feature's signature; print a clear PASS/FAIL and exit non-zero
#   on fail. SRVLOG=$(rig_server_log)
#   rig_wait_event "$SRVLOG" 'your deterministic proof line' 25 0.5 || { echo "FAIL: no proof"; exit 1; }
#   echo "PASS"

echo "repro-template: fill in the TODO blocks for your specific feature."
