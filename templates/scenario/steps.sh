# shellcheck shell=bash
# @NAME@ — the choreography: verbs only (no pipes, redirections, subshells or external commands;
# `local`, variables, if/for/case are fine). Players are names from PLAYERS. Full table, defaults and
# statuses: docs/SCENARIO-FORMAT.md §3. Check with `bin/rig lint <dir>` before a run.
#
# Lifecycle  boot <p>...                 start the server (first call) and these players' clients
#            login <p> [returning|fresh] log in; waits for the server's "[rig-bridge] player <p> in"
#            logout <p>                  stop the client; waits for "... player <p> out"
#            settle <secs> "<reason>"    sleep (the reason is required)     wiggle   restart the idle wiggler
# Input      key <p> <keysym>...         hold <p> <key|mouse1|mouse3> <secs>     type <p> "<text>"
#            mouse <p> <x> <y>           click <p> <x> <y>        rmb <p>         cast <p>
#            look <p> <dx> <dy>          turn <p> <dx> <steps>    chat <p> "/cmd"   hidechat <p>
#            scroll <p> <quickkey> [<closekey>|none] [until server <ERE> <cap> tries <n>]
# Setup      console <p> "<mwscript>"    console-file <p> setup/<f>.console     server <p> "<lua>"
#            console-object <p> "<cell>" <refnum>-<mpnum> "<mwscript>"     save <p> | save cell "<cell>"
#            (pushed by the server to a logged-in player; no bridge answer stops the run as INFRA)
# Probe      probe <p> <cell|stats|quest|topics|inv|nearby|time|weather|dump>   (PROBE=1 in scenario.conf)
#            assert probe <p> <kind> <field><op><value>...   ops = != < <= > >= ~ (quote: 'dist<400')
#            assert probe-delta <p> <kind> <field> <op> <n> [<cond>...]   (the last two requests)
# Waits      wait server <ERE> [cap]     wait client <p> <ERE> [cap]     wait probe <p> <ERE> [cap]
#            wait stable <p> <crop|FULL> [cap]
# Asserts    assert server <ERE> [cap]   assert client <p> <ERE> [cap]   (log past the last mark)
#            assert absent server|client <p> <ERE>                       (whole log)
#            assert count server|client <p> <fixed> <op> <n>             (whole log; quote the op: '>=')
#            assert json <relpath> '<python expression on d>'            (server data/<relpath>)
# Frames     shot <p> <name> [WxH+X+Y]   compared to reference-images/<name>.png; none yet = UNBLESSED
#            pair <name> <A> <B> [metric] [floor]   two shots must differ (motion, an avatar appearing)
#            signature [name]            the server log's event signature vs reference-logs/<name>.events
# Misc       mark [name]   note "<text>"   artifact <relpath> [name]    --since <mark> widens a wait/assert
#
# Log windows: a lifecycle, input, setup or custom verb marks every log when it starts acting, so put
# each assert right after the verb that causes its line. To assert an effect after other verbs have
# moved the mark, name a mark before the trigger and widen to it:
#     mark before-cmd
#     chat a "/mycommand"
#     key b space
#     assert server --since before-cmd 'my command ran'
# Coordinates: the screen is 1280x720, the client window 800x600 centred (centre 640,360).

@EACH@boot @P@
@EACH@login @P@
@EACH@hidechat @P@                              # the chat window would swallow clicks and keys

# TODO: drive the feature under test and assert where it is authoritative, e.g.
#   chat @FIRST@ "/mycommand"
#   assert server 'the line your server script logs'
#   shot @FIRST@ 10-@FIRST@-result 240x300+520+340

assert absent server "$RIG_TRIPWIRES"           # no server-script error or crash in the whole run
signature                                       # UNBLESSED until reference-logs/@NAME@.events is blessed
