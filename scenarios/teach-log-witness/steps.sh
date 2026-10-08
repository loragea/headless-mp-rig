# shellcheck shell=bash disable=SC2148
# teach-log-witness — a log line as the witness. Verbs: docs/SCENARIO-FORMAT.md §3.
#
# The window rule: before a lifecycle or input verb acts, the runner marks the end of every log.
# `wait` and `assert server|client` then read only what came after that mark, so a line matches only
# if the verb just before caused it. Put each assert right after its verb.

boot a                                                       # start the server and a's client
login a                                                      # a logs in first, so a owns the cell
assert server 'Authority of cell 0, -7 is now a'             # server line written during `login a`: inside the window
mark before-b                                                # a named mark, to come back to after later verbs move the window
boot b                                                       # b boots only now: a client idling at its name box drowns
login b                                                      # waits for the bridge's "[rig-bridge] player b in"
wait client a 'Server says DedicatedPlayer b moved to 0, -7' 20   # a's client built b from packets; `wait` polls up to 20 s
assert client a 'b \([0-9]+\) has joined the server'         # an ERE (grep -E): escape the parentheses
assert client b 'Server says DedicatedPlayer a moved to 0, -7'    # and the other direction: b's client built a
hidechat a                                                   # an input verb: it moves the mark past the login lines
assert server --since before-b 'Adding b to Cell 0, -7'      # --since widens the window back to the named mark
assert count server '[teaching-breath] water breathing pushed to' = 2   # whole log, fixed string: one per login
assert absent client a 'committed suicide'                   # whole log: a never drowned
assert absent server "$RIG_TRIPWIRES"                        # whole log: no server-script error or crash
