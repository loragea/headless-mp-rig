# teach-motion-pair — two frames that must differ

Some outcomes are visible but never the same twice frame for frame: an avatar walking, a spell
effect playing. A stored reference image cannot gate them. A `pair` can: take two shots of the same
view and require that they differ. Nothing is blessed.

```sh
bin/rig run scenarios/teach-motion-pair       # about 2 minutes on software GL; exit 0 = pass
```

## What it teaches

- **`pair <name> <A> <B> <metric> <floor>`** passes when shots A and B differ by at least the
  floor (ImageMagick `compare`, RMSE 0-1 here). The shots are taken with `shot <p> <name> <crop>`
  and need no reference: a shot used only as a pair input is not compared to anything.
- **Shoot from the observer.** b presses the keys on b's display; the shots are a's. The question is
  whether a sees what b did.
- **Crop to where the event lands, not to the actor.** b's avatar sways in its idle animation even
  when b stands still, so a crop on b differs with no event at all. The crop (`P_CROP`) is empty
  floor beside b that b strafes into.
- **A control.** Two frames of the crop with nobody moving must NOT differ (`still`, a custom verb in
  `hooks.sh`: SCENARIO-FORMAT.md §3.8). It proves the crop is quiet when nothing happens, so a pair
  that passes measured b's move and not noise.
- **Pick the numbers from measurements.** Run it a few times and read the values in `steps.tsv` and
  `run.log`. Measured here: the control 0.0014-0.0022, the event 0.038 (b drawn as the model) to
  0.073 (b drawn as the missing-mesh placeholder; both happen on this content). The ceiling (0.005)
  and floor (0.015) sit with a margin on both sides.

## What a red means

- `pair 12-a-sees-b-move` FAIL: a's view of that spot did not change. b's move did not reach a (no
  position sync), or b did not move at all (check `client-b.log`; on this content a missing
  water-breathing push freezes everyone, see `../teaching-fixture/README.md`).
- `still` FAIL: the crop changed with nobody moving: something else is in it (b's avatar drawn
  wider than expected, a chat window, a camera that moved). Open the shots under `shots/`; the
  measured value is in `run.log`. Fix the crop; do not raise the ceiling past the event's values.

## Make it your own

Keep the three shots (quiet, quiet, after) and the control; change the action between them and the
crop to the place on the observer's screen where its result appears.
