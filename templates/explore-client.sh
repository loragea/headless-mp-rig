#!/usr/bin/env bash
# explore-client.sh — long-lived SINGLE-client harness for MANUAL exploration of an input mechanic
# or an unknown headless action (docs/WRITING-SCENARIOS.md "The manual exploration loop").
#
# Boots ONE client into a fixture, logs a player in, and STAYS UP so you can drive attempts from
# separate shells and iterate fast — one action -> screenshot -> read screenshot -> check the log ->
# adjust -> repeat — instead of re-running a whole scenario per attempt. This is a throwaway probe,
# NOT a blessed test. Record what you learn in docs/cookbook/ so a Tier-C action becomes Tier-B.
#
# Usage:  FIXTURE=/path/to/scenarios/foo  PLAYER=a  [CONTENT=example]  [OVERLAY=dir]  explore-client.sh
#         CONTENT names a content profile in rig.conf (RIG_CONTENT_<name>_*; default example).
#         OVERLAY is an optional CoreScripts overlay dir (e.g. the scenario's own hooks).
# Tear down: stop the background job (the EXIT trap cleans up), or:
#   pkill -x "$RIG_CLIENT_BIN"; pkill -x "$RIG_SERVER_BIN"; pkill -x Xvfb
set -uo pipefail
DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
# shellcheck source=../lib/rig.sh
source "$DIR/../lib/rig.sh"
trap rig_cleanup EXIT

FIXTURE=${FIXTURE:-}                       # a scenario fixture dir (6 stateful subdirs); empty = blank world
PLAYER=${PLAYER:-a}                        # player name to log in (password = name by convention)
PLAYER_PASS=${PLAYER_PASS:-$PLAYER}
CONTENT=${CONTENT:-example}                # content profile name in rig.conf
OVERLAY=${OVERLAY:-}                       # optional CoreScripts overlay dir

rig_run_dir explore >/dev/null
CLILOG=$RIG_RUN_DIR/client-$PLAYER.log
rig_corescripts_overlay "$RIG_RUN_DIR/corescripts" ${OVERLAY:+"$OVERLAY"}
rig_check_prereqs
rig_require_clean
rig_set_server_home
rig_use_content "$CONTENT"

[ -n "$FIXTURE" ] && rig_load_scenario "$FIXTURE"
rig_make_profile
rig_start_xvfb
rig_start_server
rig_start_client "$CLILOG"
echo "client booting..."
rig_wait_boot "$CLILOG"
rig_login "$RIG_DISPLAY" "$PLAYER" "$PLAYER_PASS" 0 "$CLILOG"
sleep 3
rig_start_idle_wiggler
echo "=== $PLAYER logged in; rig UP on $RIG_DISPLAY ==="
echo "server log: $(rig_server_log)"
echo "client log: $CLILOG   (run dir $RIG_RUN_DIR)"
echo "drive with: DISPLAY=$RIG_DISPLAY xdotool ...  ;  DISPLAY=$RIG_DISPLAY import -window root /tmp/x.png"
sleep 100000
