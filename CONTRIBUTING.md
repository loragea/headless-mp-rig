# Contributing

The rig grows from real tests: most changes start as "a test I am writing needs X". Keep that loop
short and keep the rig general.

## Check your change

Needs `bash`, `shellcheck` and ImageMagick 7 (the `magick` command). No game binary or game data.

```sh
shellcheck -S warning lib/*.sh bin/*.sh bin/rig templates/*.sh
lib/compare.sh selftest
lib/logcheck.sh selftest
lib/scenario.sh selftest
lib/stats.sh selftest
lib/calibrate.sh selftest
bin/rig run --dry-run scenarios/example
bin/rig lint scenarios/example
bin/rig new /tmp/t1 --players "a b" --content example && bin/rig lint /tmp/t1
```

CI (`.github/workflows/ci.yml`) runs exactly these commands. A change to the rig's runtime
behaviour should also pass `bin/rig run scenarios/example` against your own build; that needs a compiled
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
   thresholds), or a step in `scenarios/example/steps.sh` when the free example content can exercise it.
3. Document it. A headless recipe is a new file in `docs/cookbook/` named by its ID,
   `KB-<n>-<slug>.md`: `n` is the next free number, `slug` is 2–6 lowercase kebab words that make
   sense to a reader who has not seen the recipe. Line 1 is `# <ID> — <title>: <one-phrase
   abstract>`, line 2 is `Read when: <the situation that sends a reader here>`, then its confidence
   tag (meanings in [docs/cookbook/README.md](docs/cookbook/README.md)) and the OpenMW version it was
   checked on. Cite recipes by their full ID. Don't add an index; the directory listing is the
   catalog. `KB` numbers are never reused or renumbered, because other projects cite them. Anything
   else goes in the fitting doc (`docs/VERIFICATION.md`, `docs/WRITING-SCENARIOS.md`,
   `docs/FEATURE-TESTS.md`).
