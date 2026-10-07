#!/usr/bin/env bash
# explore-client.sh — long-lived SINGLE-client harness for MANUAL exploration of an input mechanic
# or an unknown headless action (docs/WRITING-SCENARIOS.md "The manual exploration loop").
#
# Boots ONE client into a fixture, logs a player in, and STAYS UP so you can drive attempts from
# separate shells and iterate fast — one action -> screenshot -> read screenshot -> check the log ->
# adjust -> repeat — instead of re-running a whole scenario per attempt. This is a throwaway probe,
# NOT a blessed test. Record what you learn in docs/cookbook/ so a Tier-C action becomes Tier-B.
#
# Usage:  FIXTURE=/path/to/scenarios/foo  PLAYER=a  explore-client.sh
#         (for real game data, set the content env below; defaults to the free example-suite)
# Tear down: stop the background job (the EXIT trap cleans up), or:
#   pkill -x "$RIG_CLIENT_BIN"; pkill -x "$RIG_SERVER_BIN"; pkill -x Xvfb
set -uo pipefail
DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
source "$DIR/../lib/rig.sh"
trap rig_cleanup EXIT

FIXTURE=${FIXTURE:-}                       # a scenario fixture dir (6 stateful subdirs); empty = blank world
PLAYER=${PLAYER:-a}                        # player name to log in (password = name by convention)
PLAYER_PASS=${PLAYER_PASS:-$PLAYER}

rig_check_prereqs
rig_require_clean
rig_set_server_home

# Content. Default: OpenMW's free example-suite (set EXAMPLE_SUITE to its data/ dir). For real
# Morrowind, export MW_DATA + the three content/BSA sets instead (see the commented block).
EXAMPLE_SUITE=${EXAMPLE_SUITE:-$HOME/example-suite/game_template/data}
if [ -n "${MW_DATA:-}" ]; then
    rig_set_required_datafiles Morrowind.esm ${MW_EXTRA:-}
    rig_add_content mw "data=$MW_DATA" "fallback-archive=Morrowind.bsa" \
        ${MW_ARCHIVES:-} "content=Morrowind.esm" ${MW_CONTENT:-}
else
    rig_set_required_datafiles template.omwgame   # prepends builtin.omwscripts (client entry 0)
    rig_add_content example "data=$EXAMPLE_SUITE" "content=template.omwgame"
fi

[ -n "$FIXTURE" ] && rig_load_scenario "$FIXTURE"
rig_make_profile
rig_start_xvfb
rig_start_server
rig_start_client /tmp/mp-rig-explore.log
echo "client booting..."
rig_wait_boot /tmp/mp-rig-explore.log
rig_login "$RIG_DISPLAY" "$PLAYER" "$PLAYER_PASS" 0 /tmp/mp-rig-explore.log
sleep 3
rig_start_idle_wiggler
echo "=== $PLAYER logged in; rig UP on $RIG_DISPLAY ==="
echo "server log: $(rig_server_log)"
echo "client log: /tmp/mp-rig-explore.log"
echo "drive with: DISPLAY=$RIG_DISPLAY xdotool ...  ;  DISPLAY=$RIG_DISPLAY import -window root /tmp/x.png"
sleep 100000
