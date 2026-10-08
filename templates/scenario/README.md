# @NAME@

TODO: what this scenario proves, and the regression it guards (one paragraph).

- Players: @PLAYERS@. Content profile: `@CONTENT@` (rig.conf `RIG_CONTENT_@CONTENT@_*`).
- Fixture: TODO: where the server state in `player/` (and the other state dirs) came from:
  docs/WRITING-SCENARIOS.md §1-2.

```sh
bin/rig lint <this dir>       # seconds; no boot
bin/rig run <this dir>        # exit 0 pass, 1 fail, 2 regression, 3 infrastructure, 4 content missing
bin/rig explain latest        # on a red run: each failing step and the file to open
bin/rig up <this dir>         # explore the world by hand; bin/rig down to stop it
```

Blessing a reference is a human decision: copy the candidate of a green run
(`shots/<name>.png` -> `reference-images/<name>.png`, `review/<name>.events` -> `reference-logs/`)
and commit it with the build it was captured on (docs/VERIFICATION.md §5).
