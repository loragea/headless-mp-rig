# teach-reference-frame — a frame compared with a blessed reference

When the outcome is a view that must look the same every run (a GUI state, a framing, a shader), a
capture is compared with a stored reference image within a measured tolerance. This scenario holds
one blessed reference: a's view of the empty floor at noon.

```sh
bin/rig run --strict-refs scenarios/teach-reference-frame   # about 1 minute; exit 0 = pass, 2 = regression
```

## What it teaches

- **`shot <p> <name> <crop>`** with `reference-images/<name>.png` present is compared using the
  metric and threshold in `reference-images/manifest.tsv`. Over the threshold is `REGRESSION`
  (exit 2). Without a reference it is `UNBLESSED` (exit 0), or `NO-REFERENCE` (a failure) under
  `--strict-refs`: use that flag in CI so a missing reference cannot pass silently.
- **Make the view repeatable first.** Lighting follows the hour, so `setup/pin-hour.lua` sets it and
  stops the clock (`server-file`), and `wait probe a time …` confirms the client took it. The weather
  cannot be pinned here (cell `0, -7` has no region), so it is asserted instead: if it ever differs,
  the run fails on that line rather than as a confusing frame regression.
- **Crop to what is stable.** The crop leaves out the sky (clouds drift), the HUD and the chat
  notice. One player only: another avatar would sway in its idle animation.
- **The tolerance is measured.** `bin/rig calibrate <dir>` ran the scenario 3 times in capture mode
  and measured the spread between captures; the rule (docs/VERIFICATION.md §3) is
  tolerance = max(floor, 1.5 × spread), floors RMSE 0.01 / PHASH 8, not blessable above RMSE 0.05 /
  PHASH 25. This frame:

  | Shot | Metric | Spread (RMSE) | Spread (PHASH) | Freaks | Tolerance | Medoid |
  |---|---|---|---|---|---|---|
  | `20-a-noon-view` | RMSE (a crop) | 0.0071 | 0.69 | none | 0.011 | run-1 |

  After looking at the contact sheet, `bin/rig bless <calibration.json> <dir> --note "<why>"` copied
  the medoid into `reference-images/` and wrote the manifest row with the date, build and note.
  Later passing runs measured 0.0027-0.0030.

## What a red means

- `shot` `REGRESSION`: the view changed. `bin/rig explain latest` names the candidate, the reference
  and the difference image. Find out why: lighting, a rendering change, a camera moved. If it is a
  bug, fix the code and keep the reference.
- **Re-bless only after a verified, intended change in what the frame shows**, with
  `bin/rig calibrate` then `bin/rig bless … <name> --replace --note "<why>"`. Never re-bless because
  the test failed: that turns the regression into the new reference.
- `wait probe a time` or `assert probe a weather` FAIL: the view's preconditions did not hold, so
  the frame was not taken.

## Make it your own

Pin your view's conditions, shoot it with a crop around what must stay the same, then
`bin/rig calibrate` and `bin/rig bless` it. A reference built from commercial game data is that
game's content: keep it out of a public repo (`scenarios/local/` is gitignored).
