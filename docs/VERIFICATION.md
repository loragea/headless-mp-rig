# Verification: logs, static references, dynamic pairs

Every run produces two kinds of signal. Choose the weakest sufficient one for each assertion — a
log gate beats a screenshot whenever the feature leaves a log trace.

- **Logs — the deterministic gate.** Inline `rig_wait_event` asserts grep the server/client log for
  each feature's proof, and `lib/logcheck.sh` compares a normalized **event signature** of the whole
  run to a blessed one (catching a sync packet/callback that *stopped firing* — invisible to a
  screenshot, fatal to multiplayer).
- **Screenshots — the rendering gate.** `lib/compare.sh` compares each checkpoint frame to a blessed
  reference with a per-image tolerance (**STATIC**), or a script gates a **DYNAMIC** frame pair on the
  motion *between* two frames.

---

## 1. What is (and isn't) in the log — design assertions around it

The single most important thing before writing assertions: **the server logs only a subset of
packets at INFO**, so not everything a player does is checkable. On a typical TES3MP-lineage build:

**The server log (INFO) records:** authority transfer (`Authority of cell <X> is now <P>`), cell
change (`ID_PLAYER_CELL_CHANGE`, `Adding/Removing <cell> to/from Player <P>`), `ID_PLAYER_BASEINFO`,
object hit/sound/activate/place/delete/state (`ID_OBJECT_HIT from <P>`, `… played sound <s>`,
`Accepted ObjectPlace/ObjectActivate/ObjectDelete from <P> … for objects: <refId>`), console
commands, inventory-item use and add/remove, actor equipment / active spells.

**It does NOT log:** player position/movement, drawState (weapon/spell stance), the attack/cast input
itself (a cast surfaces only as an `ID_OBJECT_HIT` on the *target* plus a hit-sound), or NPC
combat-AI state. **The client log** records DedicatedPlayer cell movement (`Server says
DedicatedPlayer <P> moved to <cell>`), joins, and allies — which is how you prove one client *saw*
another change cell.

**Design rule — express each assertion in something that IS logged.** When the feature's own packet
isn't logged, restate the assertion as a logged consequence:

- "b isn't frozen after the cell owner leaves" → **authority transfers to b** (`Authority of cell …
  is now b`). (Not "b moved" — position isn't logged.)
- "b entered the shack" → **cell add / cell change**. (Not a position.)
- "c cast the frost scroll" → **`ID_OBJECT_HIT from c` + the hit-sound** on the target. (There is no
  "cast" line.)

This converts a visual-only check into a deterministic one and is the core trick of scenario design.

### The log signature (`lib/logcheck.sh`)

Logs are noisy (timestamps, IP:port, hex addresses, refnums, pids), so a byte-diff always fails.
`logcheck.sh` extracts a normalized **ordered sequence of significant events** — matched by a
deliberately **narrow** vocabulary (`RIG_LOG_MARKERS`) so a live multi-client run's inherent
non-determinism (ambient cell loads, weather ticks, connect-order races) doesn't drift every run — and
diffs *that*. Keep only events that (a) validate a checkpoint and (b) fire deterministically, plus the
error tripwires that must stay **absent** (`Error in frame`, `script error`, crashes). Override the
vocabulary per run with `RIG_LOG_MARKERS`; mask a newly-noisy token by extending `_log_normalize`.

Run `lib/logcheck.sh selftest` — synthetic logs prove identical→PASS, volatile-only-diff→PASS
(normalization), missing-event→REVIEW.

---

## 2. Three checkpoint classes — when to use which

| Class | Use when | Mechanism | Verdict on miss |
|---|---|---|---|
| **Log-gated** | the outcome leaves a deterministic log line | `rig_wait_event` / log signature | hard fail |
| **STATIC reference** | the outcome is a **stable** frame that must not change | `compare.sh` vs a blessed ref, per-image tolerance | regression |
| **DYNAMIC pair** | the outcome is **visible but non-deterministic** (an NPC fighting, particles) | motion *between* two same-view frames must exceed a floor | floor miss |

- **Log-gated is the real PASS/FAIL gate** — prefer it always. Authority handoff, cell
  traversal/teleport, scroll/spell hits, inventory use, one client seeing another change cell.
- **STATIC** — a frame that must be pixel-stable run to run: a GUI state, a specific framing, a
  water-shader tripwire. Blessed from the **medoid** of several calibration runs, never an arbitrary
  one. Over tolerance = a **regression** (fix the bug or deliberately re-bless), not an advisory.
- **DYNAMIC** — when the after-state is *random* so a reference is useless, take **two frames of the
  same view a few seconds apart and compare them to each other**: motion ⇒ high, static ⇒ ~0. Gate on
  `diff ≥ MOTION_MIN` (motion *present*) — the inverse of the usual "diff ≤ tolerance". This recovers
  a deterministic check for "did the NPC enter combat / did the effect render?" that the log doesn't
  record and a reference can't pin. Only the mutual delta is gated; the frame pair itself is never
  blessed.

---

## 3. ImageMagick settings

`lib/compare.sh` calls `magick compare -metric <M> [-fuzz F] ref cand diff` and reads the normalized
value. Per-image metric+threshold live in the reference set's `manifest.tsv`
(`name  metric  threshold  fuzz  description`), because **one metric never fits both** a crisp GUI and
a windy exterior.

- **RMSE** (normalized 0–1) — the default; good for GUI crops and most frames. A tight GUI crop wants
  a small threshold (~0.01–0.03); a live 3D frame with idle animation never settles that far
  (successive frames sit ~0.003–0.01 apart), so its floor is looser.
- **PHASH** (perceptual hash distance) — for 3D-heavy full frames, robust to sub-pixel jitter. **But
  PHASH is unstable on dark/sparse crops and on frames with a flickering light source** (a continuous
  brightness ramp crosses hash-bit boundaries discontinuously → bimodal scores). **Convention: GUI
  crops get RMSE; full 3D frames get PHASH** — and if a full-frame interior flickers, either move to a
  stable-lighting venue or crop the shot to the GUI element it actually asserts (COOKBOOK KB-19).
- **`-fuzz`** — treats colours within a percentage as equal before counting; use sparingly for
  antialiasing noise. Default off.
- **Differential motion (DYNAMIC):** `magick compare -metric RMSE t0.png t1.png null:` → the value in
  parens. Gate `≥ floor`.

**Freak-frame handling.** A single instantaneous grab can catch a frame mid-render (a MyGUI fade-in,
an un-drawn 3D preview) — a "freak" wildly off the ref. `capture`/`shot` helpers **re-grab** (up to a
retry count, while the scene is still live) when a grab exceeds a *freak ceiling* that sits above
normal jitter and below the freak band, handing the best frame to the unchanged compare. This never
changes the verdict (compare is still vs the manifest **threshold**, not the ceiling), so it cannot
mask a regression — it only removes transient capture noise.

**Calibrate thresholds honestly, don't hand-tune.** Measure the real run-to-run spread over several
clean runs and set each STATIC tolerance to a gap-rejected max-deviation × margin, where gap-rejection
drops only true partial-render freaks and **keeps** legit high-variance samples. A genuinely variable
3D frame then gets an honest (not artificially tight) tolerance, and a real regression still trips it.

Run `lib/compare.sh selftest` — synthetic scenes prove identical→PASS, tiny-change→PASS (within tol),
big-change→REVIEW (+ a diff image written). No game data or binaries needed.

---

## 4. Capturing and naming shots

- **Shoot from the OBSERVER's display, not the actor's.** The thing under test is cross-client
  *sync* — whether b *sees* what c did — so the camera that matters is the witness's.
- **Name `NN-<observer>-<assertion>.png`** (`16-b-spell-effect`): step order, whose display, what the
  frame must show. Self-documenting and sorts in run order.
- **`captures.tsv`** (the rig writes a wall-clock line per shot) lets you align a flagged screenshot
  with raw log timestamps when diagnosing — keep the raw server log alongside the shots.
- **Timed transient:** for a sub-second effect, don't try to time the shot — **ring-record** frames
  around the event and keep the extreme one (COOKBOOK KB-14). For a simpler case, fire the observer's
  capture in the background partway into the actor's action.

---

## 5. Re-blessing is a human decision

A screenshot or log-signature move is a **regression**, not an advisory. Resolve it one of two ways:

- **Regression** — a change broke something. **Fix the code**; the reference stays.
- **Legitimate change** — the engine genuinely changed graphics / AI / the packet sequence. The
  reference is stale and must be re-blessed (`promote_shot` / `promote_log`, and re-record which base
  moved it).

Never re-bless unattended — a unilateral re-bless enshrines regressions and defeats the gate. Keep a
**baseline set captured from an unmodified upstream build** so that a regression introduced later
can't be silently enshrined by a mid-stream re-bless; adjudicate the current build against that
archived baseline at each checkpoint.
