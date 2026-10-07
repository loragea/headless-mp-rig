# KB-19-phash-bimodal-crop-gui-rmse — A flickering light makes PHASH bimodal: crop to the assertion, use RMSE for GUI crops
Read when: a full-frame interior STABLE shot's PHASH score splits into two clusters, or a calibrated PHASH threshold flakes.

**Confidence: VALIDATED**

A flickering light source oscillates the brightness of an interior 3D scene by several percent. RMSE
barely notices (identical-looking frames stay ~0.002–0.004 apart), but **PHASH quantizes DCT
coefficients, so a continuous brightness ramp crosses hash-bit boundaries discontinuously**. Grabs
taken in the dim phase score low against the medoid (e.g. 3–10), bright-phase grabs high (e.g.
31–36), and nothing falls in between.

A calibration batch that happens to sample only one phase writes a threshold that a grab in the other
phase exceeds, while staying under a freak-frame re-grab ceiling, so the re-grab can't save it: a
false regression by construction.

Fixes:
- **Crop a STABLE frame to what it asserts.** A shot of an open inventory asserts GUI state, not the
  wall behind it. Crop to the window, measured with
  [KB-13-find-gui-click-coordinates](KB-13-find-gui-click-coordinates.md), inset a couple of pixels
  inside the window frame so no world pixel survives jitter, and park the cursor outside the rect.
- **Cropping alone may not tame PHASH.** The flicker can leak faintly through a translucent menu
  background (RMSE ~0.001, real but tiny), and PHASH is unstable on dark, sparse crops. Hence the
  convention: **GUI crops get RMSE; full 3D frames get PHASH**
  ([VERIFICATION](../VERIFICATION.md)).
- **Prefer stable-lighting venues** for any full-frame interior STABLE shot.
- Test a suspected confound (here: lighting) against **the metric that gates**, not against RMSE
  ([KB-5-rule-out-game-logic-confounds](KB-5-rule-out-game-logic-confounds.md)).
