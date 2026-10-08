# shellcheck shell=bash disable=SC2148
# teach-extra-content — a plugin only this scenario loads (CONTENT_EXTRA in scenario.conf).
#
# The rig adds the plugin's directory as a client data= line and its name as a content= line, after
# the profile's files and before the probe, and puts the same name at the same position in the
# server's requiredDataFiles.json. TES3MP keys object state by content-file index, so every client
# and the server must agree on the load order; a client whose list differs is refused at connect.
# The plugin (content/teach-token.omwaddon) is written by make-addon.py: one item on the floor.

boot a
login a                                                      # a's client was admitted: its plugin list matched the server's
boot b                                                       # b after a: an idle client at its name box drowns
login b                                                      # and so was b's
assert count server 'Client was allowed to connect' = 2     # whole log: both clients passed the data-file check
wait probe a items "obj=$P_ITEM" 'dist<400' 15               # a's engine holds the plugin's item near a
assert probe-count a items = 1 "obj=$P_ITEM"                 # exactly one: the reference loaded once
probe b items                                                # the same on b
assert probe b items "obj=$P_ITEM" 'name=Teaching Token' 'dist<400'   # the record's name too: b loaded the same record
assert probe-count b items = 1 "obj=$P_ITEM"
assert absent server "$RIG_TRIPWIRES"                        # no server-script error or crash in the whole run
