# KB-6-camera-turns-verify-framing — Camera turns are approximate: screenshot the entry heading before turning
Read when: a scenario step says "turn N degrees", or a turned view frames the wrong thing.

**Confidence: VALIDATED**

`rig_turn <disp> <dx> <steps>` repeats a mouse warp to `640+dx,360`. In SDL's warp mouse mode each
step applies ≈ `dx × sensitivity` of yaw, then re-centres. Empirically, at default sensitivity,
**dx=100 per step ≈ 12–15°**. To turn θ° right, total dx ≈ θ/0.13, split into steps of ≤150
(bigger single jumps merge or overshoot).

**Don't bake a fixed angle blind.** A player's *entry heading* into a cell is set deterministically
by the door/load marker, and often differs from where a human ended up walking in by hand: the
human's facing depended on their approach path. A headless door activate may land the player already
facing the subject, so the "turn right 45°" a human remembers rotates you into a wall.

- Treat a human-authored "turn N°" as intent ("frame X"), not a value.
- **Screenshot the post-entry heading first, then turn only if needed.**
- Flag the discrepancy to the scenario author; the fixture may need re-authoring, or the turn
  dropped.
