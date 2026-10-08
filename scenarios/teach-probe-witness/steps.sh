# shellcheck shell=bash disable=SC2148
# teach-probe-witness — the client probe as the witness. Verbs: docs/SCENARIO-FORMAT.md §3.4-3.6, probe §7.
#
# The probe is a read-only Lua script in every client. `probe <p> <kind>` asks p's engine for a report;
# `assert probe` reads the lines of the last answered request of that kind, so request AFTER the event.
# Prefer it to a log line when the fact is a value (a position, a count, a stance) that no log writes,
# or when you must know the receiving client got it right, not only that a packet arrived.
# A value is a sync witness only if this client could have got it from the network alone
# (SCENARIO-FORMAT.md §7 "What each field witnesses"): nearby.x y z, a nearby row's existence and
# its stance are; this client's own clock, its own cell and nearby.anim are not.

boot a                                                       # with PROBE=1, boot waits for the probe's [rigprobe:ready]
login a                                                      # a owns the cell
boot b                                                       # b after a: an idle client at its name box drowns
login b
wait probe b 'rigprobe:cell\] p=b .* seq=0 ' 15               # ERE form: b's heartbeat (seq=0) names b once b is in the world
wait probe a nearby actor=b 'dist<400' 20                     # condition form: re-ask a's engine until it holds b nearby
assert probe a nearby actor=b kind=npc                       # reads that same answer: a remote player is an NPC named after its login
assert probe a nearby actor=b 'x>4300' 'x<4400' 'y>-53300' 'y<-53200'   # at b's saved spot (4352, -53248): position packets
assert probe-count a nearby = 1 actor=b                      # exactly one copy of b: a duplicate avatar is a classic bug
probe b nearby                                               # the other direction, an explicit request
assert probe b nearby actor=a 'dist<400' stance=nothing      # stance arrives in packets too: a has nothing drawn
assert probe-count b nearby = 1 actor=a
probe b effects                                              # b's own engine: what the server pushed at login
assert probe b effects net=1 effect=waterbreathing           # own state set by the server: a witness of the push, not of a peer
assert absent server "$RIG_TRIPWIRES"                        # no server-script error or crash in the whole run
