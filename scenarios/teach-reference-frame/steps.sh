# shellcheck shell=bash disable=SC2148
# teach-reference-frame — a STATIC reference frame (docs/VERIFICATION.md §2-3, §5).
#
# `shot <p> <name> <crop>` compares the capture with reference-images/<name>.png using the metric and
# tolerance of its row in reference-images/manifest.tsv. Over tolerance = REGRESSION (exit 2). No
# reference = UNBLESSED (exit 0), or NO-REFERENCE, a failure, under --strict-refs.
# A reference only works for a view that is the same every run: pin what changes it (the hour) and
# assert what you cannot pin (here the weather: cell 0, -7 has no region, so it stays clear).
# The tolerance is measured, not chosen: `bin/rig calibrate` runs the scenario 3 times, measures the
# spread between the captures and proposes max(floor, 1.5 x spread). `bin/rig bless` then copies the
# medoid capture and writes the manifest row. Re-bless only after a verified, intended change in what
# the frame shows, never because the test failed.

boot a
login a
hidechat a                                                   # the chat window would cover the view
server-file a setup/pin-hour.lua                             # pin the hour: lighting follows it
wait probe a time "hour>=$P_HOUR" "hour<$((P_HOUR + 1))" scale=0 10   # the client clock took the push and stopped
probe a weather                                              # what cannot be pinned is asserted
assert probe a weather weather=clear                         # the reference was blessed in clear weather
settle 4 "the sky and fog take the new hour; the chat notice fades"
shot a 20-a-noon-view "$P_CROP"                              # compared with reference-images/20-a-noon-view.png
assert absent server "$RIG_TRIPWIRES"                        # no server-script error or crash in the whole run
