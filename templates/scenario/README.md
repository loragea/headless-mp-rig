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

Blessing a reference is a human decision: `bin/rig calibrate <this dir>` measures several capture
runs and proposes a tolerance; after reviewing its contact sheets, `bin/rig bless <calibration.json>
<this dir> --note "<why>"` copies the candidates and writes the manifest rows (docs/VERIFICATION.md §5).
