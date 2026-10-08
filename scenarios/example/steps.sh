# shellcheck shell=bash disable=SC2148
# The example's choreography. Verbs: docs/SCENARIO-FORMAT.md.
boot a
login a                                     # a first -> cell authority
hidechat a
shot a 10-a-before-b 240x300+520+340        # t0 of the pair: the spot in front of a where b will stand
boot b                                      # b boots late: a client idling at the name box drowns
login b                                     #   ~45 s after start on this all-underwater content
wait client a 'DedicatedPlayer b' 20 --since start
settle 8 "mutual DedicatedPlayer sync settles"
shot a 11-a-after-b 240x300+520+340
pair 11-a-sees-b 10-a-before-b 11-a-after-b RMSE 0.005  # b's avatar: 0.017 (model) to 0.06 (placeholder); no b: 0
shot b 20-b-minimap 88x84+950+576           # STABLE: both markers on b's minimap
assert count server 'Client was allowed to connect' '>=' 2
assert server --since start 'Authority of cell 0, -7 is now a'
assert client b 'DedicatedPlayer a' --since start
assert absent server "$RIG_TRIPWIRES"
signature example-server
