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

- **`example/`** — a runnable example built on OpenMW's freely-licensed **example-suite** content
  (no commercial game data required). *(Being authored — it needs live rig runs to capture and bless
  its references.)*
- **`local/`** — gitignored. Put any fixture derived from a commercial game's data (Morrowind saves,
  gameplay screenshots) here; it is game-content, not MIT-covered, and must stay out of a public repo.
