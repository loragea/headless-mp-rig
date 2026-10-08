# teach-probe-witness — the client probe as the witness

The same fact as `teach-log-witness` ("each client sees the other"), proved from inside the
receiving client's engine with the client probe instead of a log line.

```sh
bin/rig run scenarios/teach-probe-witness     # about 2 minutes on software GL; exit 0 = pass
```

## What it teaches

- **`PROBE=1`** loads a read-only Lua player script into every client (OpenMW 0.48 or later). It
  prints engine state as `[rigprobe:<kind>]` lines into the client log, which the runner copies to
  `probe-<p>.log`.
- **Request, then assert.** `probe b nearby` asks b's engine for the actors around b and waits for
  the answer; `assert probe` and `assert probe-count` read only the last answered request of that
  kind, so an answer from before the event can never pass.
- **`wait probe`, two forms.** With a kind and conditions it re-asks until one line meets all of them
  (use it instead of a `settle` when the state arrives after an unknown delay). With an ERE it polls
  `probe-<p>.log` for the probe's own lines, such as the `seq=0` heartbeat.
- **When the probe beats a log line.** The log can say "a packet about b arrived"; the probe says
  where a's engine put b, how many copies of b it holds, and b's stance. Assert the log when the
  server's acceptance matters, the probe when the receiving client's state matters, both when both do.
- **Local versus synced fields.** A probe value witnesses sync only if the observing client could
  have got it from the network alone. `nearby` rows, `x y z` and `stance` come from packets;
  `anim` is played by the observer's own animation controller, its own `cell` follows its own
  movement and `time` is its own clock. The table is in docs/SCENARIO-FORMAT.md §7. The last assert
  here reads b's own state on purpose: it witnesses the server's push, not another player.

## What a red means

- `wait probe a nearby actor=b` FAIL: a's engine never held an actor named b within 400 units. The
  FAIL row quotes the last answer: no row at all means b was never created; a row with a large
  `dist` means b was created in the wrong place.
- `assert probe-count … = 1` FAIL with a count of 2: a duplicate remote avatar.
- A probe verb `SKIP`: the client is older than OpenMW 0.48 or lacks that kind (`caps=` in the
  `ready` line). `SKIP` is not a pass; check `probe-<p>.log`.

## Make it your own

Change the kind and conditions to the state your feature leaves in the observer's engine, for
example `assert probe b nearby actor=a stance=weapon` after `key a f` (a draws a weapon). Check the
field's row in the witness table first.
