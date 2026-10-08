#!/usr/bin/env bash
# explore-client.sh — replaced by `bin/rig up`. To explore an action by hand, bring a scenario's world
# up, drive it from other shells, and stop it:
#   bin/rig up scenarios/example a      # boots the server and player a's client, logs a in, stays up
#   DISPLAY=:99 xdotool key Return      # drive;  DISPLAY=:99 import -window root shot.png  # capture
#   bin/rig down                        # stop everything
# The loop (one action, a screenshot, the log, adjust): docs/WRITING-SCENARIOS.md §8.
echo "explore-client.sh is replaced by: bin/rig up <scenario dir> [player] (see the header of $0)" >&2
exit 64
