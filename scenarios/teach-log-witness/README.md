# teach-log-witness — a log line as the witness

The simplest useful multiplayer test: two players log in, and lines in the server log and in each
client's log prove that each client created the other. Start here.

```sh
bin/rig run scenarios/teach-log-witness       # about 2 minutes on software GL; exit 0 = pass
```

## What it teaches

- **A log line is the witness.** A multiplayer fact ("a sees b") is proved by a line that only exists
  if the fact happened: `Server says DedicatedPlayer b moved to 0, -7` is written by a's client when
  it creates b's avatar from network packets.
- **`assert` versus `wait`.** Both read the log past the last mark. `wait` polls up to its cap and
  is the natural first check after a slow event; `assert` polls too (10 s by default), so either
  works for a line that arrives late. Use `wait` where you mean "the next step needs this".
- **The log window and `mark`.** Every lifecycle and input verb marks the end of each log before it
  acts, so an assert right after a verb sees only what that verb caused. `mark <name>` names a point;
  `--since <name>` widens a later assert back to it (here, past the `hidechat` that moved the mark).
- **Whole-log checks.** `assert count` and `assert absent` read the whole log: a count of a fixed
  string, or a line that must never appear (`$RIG_TRIPWIRES` is the rig's list of server errors).

Which lines your build writes is your build's business: grep a run's `server.log` and
`client-<p>.log` for candidates (docs/VERIFICATION.md §1 lists what a TES3MP-lineage server logs).

## What a red means

- `wait client a 'Server says DedicatedPlayer b …'` FAIL: a's client never created b. That is the
  bug class this rig exists for (players cannot see each other). Read `client-a.log` past the
  window `bin/rig explain latest` names.
- `Authority of cell …` FAIL: login order no longer sets cell authority, or the line changed.
- `login` FAIL (RESULT `INFRA`, exit 3): the player never got in; nothing after it ran.

## Make it your own

Replace the quoted lines with the lines your feature writes: do the action, then assert the line
it causes right after it.

The fixture (`../teaching-fixture`) is shared by every `teach-*` scenario; its README says why it
exists and what the free content needs.
