# KB-15-screen-stability-wait — Screen-stability wait: gate a GUI transition on the frame, with a pre-keystroke baseline
Read when: waiting on a dialog swap, a loading overlay or any transition that no log line marks.

**Confidence: VALIDATED**

For a wait whose proof is in no log (a MyGUI dialog swapping in, a loading overlay clearing), gate on
the **screen**: `rig_wait_stable <disp> <geom|FULL> <cap> <interval> <eps> <delta> [baseline.png]`
returns once the region has (a) **changed** from the baseline by ≥ delta, then (b) **held still**
across two consecutive grabs within eps (normalized RMSE). The change gate stops a slow transition
from being declared ready while it still shows the previous dialog; the stability gate rides out
fade-ins and partial renders. Pass `-` as delta to skip the change gate when there is no discrete
transition.

Two calibrated facts:
- **Grab the baseline BEFORE the triggering keystroke** (`rig_grab_region`, passed as the last
  argument). A dialog that swaps in faster than a call-time first grab makes the change gate
  unsatisfiable (it baselines the new content) and the wait silently burns its whole cap.
- **eps is content-dependent.** A 2D dialog crop settles to ~0 (eps ~0.004). A live 3D frame never
  settles that far (idle animation keeps successive frames ~0.003–0.01 apart), so it needs eps
  ~0.012. Measure, don't guess.

Set each cap to about 1.5× the fixed sleep it replaces. On timeout the wait warns and returns 1 and
the caller proceeds, so a degraded run just waits the cap instead of desyncing.

Log-side siblings: `rig_wait_event` (poll a log for a regex up to a cap) and `rig_wait_boot` (the
client's world-load milestone, far faster than a blind boot sleep).
