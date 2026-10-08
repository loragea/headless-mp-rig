# scenarios/

Scenario fixtures. A fixture is the six stateful server-state subdirs a scenario resumes into —
`player/ cell/ world/ map/ recordstore/ custom/` — plus its own `reference-images/` (+ `manifest.tsv`)
and `reference-logs/` for the blessed checkpoints. See **[../docs/WRITING-SCENARIOS.md](../docs/WRITING-SCENARIOS.md)**
for how to author one and **[../docs/VERIFICATION.md](../docs/VERIFICATION.md)** for the reference/manifest formats.

```
scenarios/<name>/
  player/ cell/ world/ map/ recordstore/ custom/   # the fixture (rig_load_scenario restores these)
  reference-images/   manifest.tsv                  # blessed STATIC frames + per-image metric/threshold
  reference-logs/     <checkpoint>.events           # blessed log signatures
```

- **`example/`** — a runnable two-client example built on OpenMW's freely-licensed **example-suite**
  content (no commercial game data required): both clients join one world and see each other, proven
  from a blessed server-log signature + inline log asserts. Run it with `bin/rig run scenarios/example`; see
  [example/README.md](example/README.md) for what it asserts and the example-suite quirks it works
  around. (Carries its own `settings.cfg` + `coreScripts-overlay/` compat shim so stock CoreScripts
  survive on non-Morrowind content.)
- **`teach-*/`** — the teaching set: small scenarios on the same free content, each showing one way to
  verify a multiplayer fact, every line commented. Read them in this order to learn to write your own:

  | Scenario | Pattern taught | Verbs | Witness |
  |---|---|---|---|
  | [teach-log-witness](teach-log-witness/) | a log line proves the fact; the log window, `mark`, `--since` | `wait`, `assert server\|client`, `assert count`, `assert absent`, `mark` | server and client log lines |
  | [teach-probe-witness](teach-probe-witness/) | the receiving client's engine proves it; which probe fields witness sync | `PROBE=1`, `probe`, `wait probe` (both forms), `assert probe`, `assert probe-count` | client probe |
  | [teach-setup-by-command](teach-setup-by-command/) | set up state at run time, keep one fixture; the `consoleAllowed` rule | `console`, `server`, `server-file`, then `wait probe`/`assert probe` | probe and server log |
  | [teach-motion-pair](teach-motion-pair/) | two frames must differ when something moves, a control pair must not | `shot` with a crop, `pair`, a `hooks.sh` custom verb | dynamic frame pair |
  | [teach-reference-frame](teach-reference-frame/) | a frame against a blessed reference; pin the view, calibrate, bless | `server-file`, `wait probe`, `shot`; `bin/rig calibrate`, `bin/rig bless` | static reference image |
  | [teach-extra-content](teach-extra-content/) | load a plugin for one scenario and check it on every client | `CONTENT_EXTRA`, `probe items`, `assert probe-count` | client probe |

  They share one fixture, [teaching-fixture/](teaching-fixture/) (not a scenario): two returning
  players plus the server scripts and client settings the free content needs.
- **`local/`** — gitignored. Put any fixture derived from a commercial game's data (Morrowind saves,
  gameplay screenshots) here; it is game-content, not MIT-covered, and must stay out of a public repo.
