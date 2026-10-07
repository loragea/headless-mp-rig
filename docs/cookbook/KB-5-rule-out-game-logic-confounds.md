# KB-5-rule-out-game-logic-confounds — Rule out game-logic confounds: vary one thing, test against the gating metric
Read when: about to conclude that an input technique, a wait or a capture method is unreliable.

**Confidence: METHOD NOTE**

The cautionary tale: a flaky *outcome* (a spell sometimes casting) was blamed on the *input method*
when the real cause was **game logic** (skill-based cast chance plus magicka). Headless work hides
the in-game feedback a human sees (the "spell failed" flash, the magicka bar).

- **Before concluding an input technique is unreliable, rule out the gameplay reasons the action
  would legitimately fail:** skill check, resource cost, wrong stance, a modal window, combat state.
- Use a **deterministic vehicle** (a scroll, not a low-skill spell) to isolate input, and vary one
  thing at a time.
- Test a suspected confound against **the metric that actually gates**, not a convenient proxy (see
  [KB-19-phash-bimodal-crop-gui-rmse](KB-19-phash-bimodal-crop-gui-rmse.md): frames identical by
  RMSE can still split a perceptual hash).
- Treat a human's eyeball report as a hypothesis to falsify, not to argue away. Someone who knows the
  game often resolves these confounds at once.
