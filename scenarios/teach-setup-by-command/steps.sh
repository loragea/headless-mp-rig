# shellcheck shell=bash disable=SC2148
# teach-setup-by-command — setup without editing the fixture. Verbs: docs/SCENARIO-FORMAT.md §3.4.
#
# The setup verbs go through the rig's server bridge, which pushes them to a logged-in player:
#   console <p> "<mwscript>"   p's client runs the command (queued by the server, so no kick)
#   server <p> "<lua>"         Lua inside the server, `pid` and `player` bound to p
#   server-file <p> <file>     the same, from a file, with $P_<NAME> substituted
# Each records OK once the bridge answers. OK means "sent"; assert the effect afterwards.
# The consoleAllowed rule: the command itself passes because the server queued it, but a world change
# it causes (an object placed, deleted, locked) comes back as a separate packet marked as console
# origin, and stock CoreScripts kick a player without console permission for that. Grant it first.

boot a
login a
boot b
login b
wait probe b nearby actor=a 'dist<400' 20                     # the fixture's start state, before any setup
console a "setpos x $P_X"                                    # move a by a console command the server pushes
assert server 'Accepted ConsoleCommand from a'               # a's echo of it passed the server's check
wait probe b nearby actor=a "x<$((P_X + 64))" "x>$((P_X - 64))" 10   # b sees a at the new spot: synced position
probe a cell                                                 # a's own position: a witness here only because the server moved it
assert probe a cell "x<$((P_X + 64))" "x>$((P_X - 64))"
server a "player.data.stats.level = 7; player:LoadLevel()"   # one line of server Lua: change the record and send it
probe a stats
assert probe a stats level=7                                 # the client applied what the server sent
server-file b setup/b-level.lua                              # longer setup lives in a file
probe b stats
assert probe b stats "level=$P_LEVEL"
server a "player.data.settings.consoleAllowed = true"        # the consoleAllowed rule: grant before a world-changing command
console a "placeatpc PrisonMarker 1 128 0"                   # place an object next to a (the only placeable record in this content)
wait server 'Accepted ObjectPlace from a .* prisonmarker' 8  # the console-origin ObjectPlace was accepted, not kicked
assert absent server "$RIG_TRIPWIRES"                        # no server-script error or crash in the whole run
