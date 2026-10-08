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
- **`local/`** — gitignored. Put any fixture derived from a commercial game's data (Morrowind saves,
  gameplay screenshots) here; it is game-content, not MIT-covered, and must stay out of a public repo.
