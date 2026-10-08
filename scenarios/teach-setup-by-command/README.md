# teach-setup-by-command — set up state with commands, keep one fixture

A test often needs a start state the fixture does not have: a player somewhere else, a different
stat, an object in the world. Rather than authoring a new fixture per test, push the difference
from the server at run time. The fixture (`../teaching-fixture`) stays as authored and serves every
`teach-*` scenario.

```sh
bin/rig run scenarios/teach-setup-by-command  # about 2 minutes on software GL; exit 0 = pass
```

## What it teaches

- **`console <p> "<mwscript>"`** — the server pushes a console command to p's client
  (`setpos x 3584` moves a). It goes through the server on purpose: a client that runs a console
  command the server did not queue is kicked by stock CoreScripts.
- **`server <p> "<lua>"`** — one chunk of Lua inside the server, with `pid` and `player` bound to p.
  Change the server's record of the player, then send it (`player:LoadLevel()`): the CoreScripts
  `Load*` methods do the sending.
- **`server-file <p> setup/<f>.lua`** — the same for longer setup, with `$P_<NAME>` parameters from
  `scenario.conf` substituted (`setup/b-level.lua` uses `$P_LEVEL`).
- **The `consoleAllowed` rule.** The pushed command passes the server's check because the server
  queued it. A world change it causes (here `placeatpc` placing an object) arrives as a separate
  packet marked as console origin, and stock CoreScripts kick a player without console permission
  for it: without the `consoleAllowed = true` line the server logs `Kicking player a` and the
  `wait server` fails. Grant it before any object-changing command.
- **Read the effect back.** A setup verb's `OK` means "sent". Assert what it did: the server's
  acceptance line, the other client's view (`wait probe b nearby actor=a "x<…"`: a synced
  position), and the player's own engine (`probe a cell`, `probe a stats`). Own position and stats
  are witnesses here only because the server set them.

The example-suite content has no item records (no `MISC`, weapons or ingredients), so this scenario
cannot give a player an item. On content that has them, `console <p> "additem <id> 1"` followed
by `probe <p> inv` and `assert probe <p> inv "item=<id>:1"` is the same pattern.

## What a red means

- A setup row `FAIL`: the bridge refused (player not logged in, a Lua error; the row quotes it).
  No answer at all stops the run as `INFRA`.
- `wait probe b nearby actor=a "x<…"` FAIL: the server moved a but b's engine still has a at the old
  spot: position sync is broken.
- `assert probe a stats level=7` FAIL: the server's record changed but the client never applied it.
- `wait server 'Accepted ObjectPlace …'` FAIL: the place was refused or the player was kicked
  (grep `server.log` for `Kicking player`).

## Make it your own

Replace the commands with the state your test needs, and follow each with the assert that reads it
back. Keep the fixture for what is slow or impossible to set by command (who stands where at login,
a quest history).
