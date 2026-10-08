# shellcheck shell=bash disable=SC2148
# The example's choreography. Verbs: docs/SCENARIO-FORMAT.md. Each assert reads the logs from the
# start of the last lifecycle/input verb, so it sits right after the verb that causes its line.
boot a
login a                                     # a first -> cell authority
assert server 'Authority of cell 0, -7 is now a'
hidechat a
shot a 10-a-before-b 240x300+520+340        # t0 of the pair: the spot in front of a where b will stand
boot b                                      # b boots late: a client idling at the name box drowns
login b                                     #   ~45 s after start on this all-underwater content
wait client a 'DedicatedPlayer b' 20
assert client a 'b \([0-9]+\) has joined the server'
assert client b 'DedicatedPlayer a'
settle 8 "mutual DedicatedPlayer sync settles"
shot a 11-a-after-b 240x300+520+340
pair 11-a-sees-b 10-a-before-b 11-a-after-b RMSE 0.005  # b's avatar: 0.017 (model) to 0.06 (placeholder); no b: 0
shot b 20-b-minimap 88x84+950+576           # STABLE: both markers on b's minimap
probe a nearby                              # the client probe: the actors a's engine holds
assert probe a nearby actor=b 'dist<400'    # the visibility proof: an actor named b stands near a
probe a stats
console a "ModCurrentFatigue -50"           # a console command the server pushes to a
assert server 'Accepted ConsoleCommand from a'   # a's echo of it passed the server's check: no kick
probe a stats
assert probe-delta a stats fat '<' -20      # its effect, read back from a's engine
assert count server 'Client was allowed to connect' '>=' 2
assert absent client a 'committed suicide'  # the water-breathing fixture keeps both players alive
assert absent client b 'committed suicide'
assert absent server "$RIG_TRIPWIRES"
signature example-server
