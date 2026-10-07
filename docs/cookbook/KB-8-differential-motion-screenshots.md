# KB-8-differential-motion-screenshots — Differential screenshots: gate random motion on two frames of one view
Read when: the visual outcome to check is non-deterministic (combat, particles, a crowd), so no reference frame can be blessed.

**Confidence: VALIDATED**

For a checkpoint whose visual outcome is *random*, a blessed reference is useless: you can't match a
frame you can't predict. Take **two frames of the same observer view a few seconds apart and compare
them to each other**: `magick compare -metric RMSE t0.png t1.png null:` → the normalized value in
parens. **Motion ⇒ high; static ⇒ ~0.** Gate `diff ≥ MOTION_MIN` (motion present), the inverse of
the usual "diff ≤ tolerance".

Design points:
1. Keep **every controllable foreground element identical** in both frames (toggle a weapon stance
   *before* t0, not between), so the intended mover is the only difference.
2. An epsilon floor absorbs unavoidable ambient movement (sky, smoke).
3. Take the pair where it can't disturb a later assertion (for example, before a logout whose
   authority handoff you assert next).

The pair is never blessed; only its mutual delta is gated, in the script. A frozen actor can't
produce motion, so nothing is masked. When t1 must land inside a short window, poll for it instead of
sleeping: [KB-20-motion-poll-keep-clearing-frame](KB-20-motion-poll-keep-clearing-frame.md).
