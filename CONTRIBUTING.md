# Contributing

The rig grows from real tests: most changes start as "a test I am writing needs X". Keep that loop
short and keep the rig general.

## Check your change

Needs `bash`, `shellcheck` and ImageMagick 7 (the `magick` command). No game binary or game data.

```sh
shellcheck -S warning lib/*.sh bin/*.sh templates/*.sh
lib/compare.sh selftest
lib/logcheck.sh selftest
```

CI (`.github/workflows/ci.yml`) runs exactly these three commands. A change to the rig's runtime
behaviour should also pass `bin/run-example.sh` against your own build; that needs a compiled
client and server, so it is not part of CI.

## Rules

- **Generic only.** Everything in `lib/`, `bin/`, `templates/` and `docs/` must hold for any
  OpenMW-multiplayer build running any content. No hard-coded paths, binary names, or assumptions
  about one game's cells, items or server scripts.
- **No commercial game data in the repo.** Fixtures, screenshots and log signatures derived from a
  commercial game stay out. Keep your own under `scenarios/local/`, which is gitignored. The
  committed example uses OpenMW's free example-suite content only.
- **Commit subjects read cold**: imperative mood ("Add", "Fix"), capitalised, no trailing period,
  at most 50 characters, understandable to someone who did not watch the work. Explain the why in
  the body.

## Adding a capability or recipe

1. Implement it in the library, generalized. Anything that differs between setups is a `RIG_*`
   variable with a default, documented in `rig.conf.example`.
2. Prove it: add a `selftest` case when the logic is testable without a game (masking, metrics,
   thresholds), or a step in `bin/run-example.sh` when the free example content can exercise it.
3. Document it: a headless recipe goes in `docs/COOKBOOK.md` under the next `KB-n` number, with
   its confidence tag (VALIDATED / PARTIAL / THEORY) and the OpenMW version it was checked on.
   `KB` numbers are never reused or renumbered, because downstream projects cite them. Anything
   else goes in the fitting doc (`docs/VERIFICATION.md`, `docs/WRITING-SCENARIOS.md`,
   `docs/FEATURE-TESTS.md`).
