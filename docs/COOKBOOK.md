# Headless-action cookbook

Recipes for driving the game without a human at the keyboard — the hard-won part. Each is a
technique plus *why* it works and the dead ends that look like the technique failing. Examples are
drawn from Morrowind + a TES3MP-lineage build, but the mechanics are engine-general. When you
calibrate a new action, add it here so it stops being a from-scratch problem.

> Confidence tags: **VALIDATED** (seen to work + verified via log/screenshot), **PARTIAL**,
> **THEORY**.

---

### KB-1 — Cast a spell/scroll with a synthetic left-button — VALIDATED
`xdotool mousedown 1; sleep 0.2; xdotool mouseup 1` (a plain `xdotool click 1` also works). The brief
held press is a safe default, not a requirement. **The reliability lever is the CAST, not the
button:**
- A **spell** has a skill-based **cast chance** — a low-skill caster *fizzles* most attempts, which
  looks exactly like input failure but isn't. To cast a spell reliably, either use a **scroll**
  (always succeeds, no skill check, no magicka cost) or raise the skill in the fixture/console first.
- The chat/welcome window **eats the first click** after login (a focusable window) — hide it first
  (KB-4).

There is **no** need to rebind the attack to a keyboard key; synthetic mouse buttons register as a
cast. (Keep a keyboard rebind of the use-action via a seeded `input_v3.xml` only as a fallback if a
future engine build regresses synthetic buttons.)

### KB-2 — Cast a scroll: quick-key equips+uses it; the read-parchment is combat-gated — VALIDATED
A quick-key (`1`–`0`) **equips AND uses** the bound scroll (the server logs `used inventory item
<id>`).
- **Out of combat:** it opens the **read parchment** → close it with **`space`** → then cast (KB-1).
- **In combat:** the read is blocked ("cannot read during battle"), so there is **no parchment and no
  `space`** — just cast.

So a scroll cast *before* combat needs the `space`; one *during* combat must not include it. Don't
blindly `space` every scroll.

### KB-3 — Turn an NPC hostile with a spell/scroll hit — VALIDATED
A spell/scroll **hit** on an NPC drives it hostile via server-side AI (run by the cell-authority
client): the server logs `ID_OBJECT_HIT`, a hit-sound, and active-spell lines on the NPC; subsequent
player input then shows the "cannot read during battle" gate = the player is now in combat. The NPC's
visible combat stance is a good DYNAMIC-pair checkpoint for the observing player.

### KB-4 — Hide the chat/welcome window — VALIDATED
A chat-toggle key (often **F2**, or **F6** on some CoreScripts configs) hides the chat/welcome window.
Do it right after login so it can't eat the first cast-click (KB-1); allow ~1 s to settle. Once
hidden it stays hidden for the session. Note: a fully-hidden/disabled chat window **won't reopen** on
the say-key, so a chat command sent *after* hiding it is silently dropped — send chat commands before
hiding, or log values from a server-side hook instead (see FEATURE-TESTS).

### KB-5 — One variable at a time, and beware game-logic confounds — METHOD NOTE
The cautionary tale: a flaky *outcome* (a spell sometimes casting) was blamed on the *input method*
when the real cause was **game logic** (skill-based cast chance + magicka). Headless work hides the
in-game feedback a human sees (the "spell failed" flash, the magicka bar). **Before concluding an
input technique is unreliable, rule out the gameplay reasons the action would legitimately fail**
(skill check, resource cost, wrong stance, a modal window). Use a **deterministic vehicle** (a scroll,
not a low-skill spell) to isolate input, and vary one thing at a time. Test a suspected confound
against **the metric that actually gates** — and treat a human's eyeball report as a hypothesis to
falsify, not to argue away.

### KB-6 / KB-7 — Camera turns are approximate; verify framing, don't trust angles — VALIDATED
`rig_turn <disp> <dx> <steps>` repeats a mouse warp to `640+dx,360`; in warp mode each step applies
≈ `dx × sensitivity` of yaw then re-centres. Empirically (default sensitivity) **dx=100 ≈ ~12–15°**;
to turn θ° right, total dx ≈ θ/0.13 split into steps of ≤150 (bigger jumps merge/overshoot). **But
don't bake a fixed angle blind:** a player's *entry heading* into a cell is set by the door/load
marker and often differs from where a human ended up by hand — a headless door-activate may land the
player already facing the subject, so the "turn right 45°" a human remembers rotates you into a wall.
**Screenshot the post-entry heading first, then turn only if needed**, and flag any discrepancy to the
scenario author (the fixture may need re-authoring).

### KB-8 — Differential screenshots: detect MOTION when the after-state is non-deterministic — VALIDATED
For a checkpoint whose visual outcome is *random* (an NPC fighting, particles, a crowd), a blessed
reference is useless. Take **two frames of the same observer view a few seconds apart and compare them
to each other**: `magick compare -metric RMSE t0.png t1.png null:` → the value in parens. **Motion ⇒
high; static ⇒ ~0.** Gate `diff ≥ MOTION_MIN`. Two design points: (1) keep **every controllable
foreground element identical** in both frames (toggle a weapon stance *before* t0, not between), so
the intended mover is the only difference; (2) an epsilon floor absorbs unavoidable ambient movement
(sky, smoke). The pair is never blessed — only its mutual delta is gated, in-script. A frozen actor
can't produce motion, so nothing is masked.

### KB-9 / KB-10 — Drop an inventory item into the world = two clicks; aim high for a feet-drop — VALIDATED
The engine's inventory drag-drop is **click-to-grab / click-to-release**, not a held drag:
1. open inventory (`rig_rmb` — the inventory action is the right mouse button),
2. **click the item icon once** → it lifts onto the cursor (a `count==1` item has no count dialog),
3. **click a window-free part of the screen** → it drops.

**Where it lands:** clicking on a near-flat surface within ~200 units raycast-*places* it there
(position-sensitive); clicking on a wall/ceiling/actor/too-far **drops it at the dropper's own feet**.
So for a deterministic feet-drop with no pixel calibration, **aim the second click high** (ceiling /
upper wall) where placement is impossible. Put the *geometry* (dropper facing receiver) in the
fixture, not in a calibrated click point.

### KB-11 — Pick a world item up = a first-person centre-screen activate — VALIDATED
`space` (activate) picks up the *faced* object — a ray from the camera through screen-centre,
range-limited (~192 units). So the receiver just has to be looking at the item, in normal first-person
view, within range. Put that aim in the **fixture** (a downward pitch puts the crosshair on the floor
at `eye-height / tan θ`), not in script. The one thing that breaks this is the vanity camera (KB-12) —
rule that out first; the activate itself is trivial.

### KB-12 — The vanity (idle) camera is the "camera is non-deterministic" red herring — VALIDATED
After **30 s** (`fVanityDelay`) of no input the engine swings into a slowly-orbiting third-person
vanity view that **hides the crosshair**, breaking centre-screen ray actions and re-framing
screenshots. It is fully deterministic *once you stop it triggering*. **Fix:** `rig_start_idle_wiggler`
(call once, after players are in-world) nudges the mouse 1px every `RIG_WIGGLE_INTERVAL` (< 30 s) on
every display so vanity never fires. Any unexpected third-person / no-crosshair frame = vanity;
wiggle, don't theorise. (See WRITING-SCENARIOS §5.)

### KB-13 — Find a GUI element's click coordinates headlessly — VALIDATED
There's no accessibility tree, and synthetic mouse moves don't reliably fire MyGUI tooltips. Two
techniques:
1. **Labelled coordinate grid.** Screenshot (`import -window root`), crop the region, upscale, and
   draw gridlines whose labels are the *full-res screen coordinates*, so you read a widget's centre
   straight off the picture. With ImageMagick (map `screenX = cropX0 + zoomX/scale`), pass the draw
   commands **inline** (some policies block `-draw @file`).
2. **Grab-and-identify.** Click a candidate to lift it onto the cursor (KB-9), move the floating icon
   to a clear dark area, screenshot, and read which item you grabbed; click it back if wrong.

GUI coordinates are camera-independent and stable across runs given a **fresh default-layout profile**
(the rig wipes it each run) + a **fixed fixture inventory** (deterministic sort order) — so a
coordinate found once is reusable, no per-run re-detection.

### KB-14 — A cast DURING active combat is non-deterministic — cast in the pre-melee window — VALIDATED
Casting a teleport/effect scroll while the caster is being hit fails intermittently for two vanilla
reasons, neither an input bug:
1. **An over-damaging scroll kills the target → the caster drops out of combat → the *next* cast uses
   the out-of-combat path** (read-parchment) instead of the in-combat direct cast. Tell: an
   `OnActorDeath` line. Fix: keep the target's HP above the scroll's max damage (bump
   `stats.health*` in the fixture cell JSON), or weaken the scroll.
2. **A melee hit landing mid-cast interrupts it** — the use initiates but never completes (no consume,
   no effect, no teleport). Fix: cast in the **pre-melee window** — poll for hostility rather than
   blanket-sleeping, equip the scroll early, and **retry** on an incomplete cast (an interrupted cast
   doesn't consume the scroll, so carry spares and re-key gated on the server's completion line).

**General lesson (extends KB-5):** a "flaky cast" is rarely the synthetic input — look at the combat
state at the cast instant. Diff a passing vs failing server log around the action to see which
confound fired.

### KB-15 — Screen-stability wait: gate a GUI transition on the frame, with a pre-keystroke baseline — VALIDATED
For a wait whose proof is in no log (a MyGUI dialog swapping in, a loading overlay clearing), gate on
the **screen**: `rig_wait_stable <disp> <geom|FULL> <cap> <interval> <eps> <delta> [baseline.png]`
returns once the region has (a) **changed** from the baseline by ≥ delta, then (b) **held still**
across two grabs within eps. Two calibrated facts:
- **Grab the baseline BEFORE the triggering keystroke** (pass it as the last arg). A dialog that swaps
  in faster than a call-time first grab makes the change-gate unsatisfiable and the wait burns its cap.
- **eps is content-dependent:** a 2D dialog crop settles to ~0 (eps ~0.004); a live 3D frame never
  settles that far (idle animation keeps frames ~0.003–0.01 apart) so it needs eps ~0.012. Measure,
  don't guess.
Caps ≈ the old fixed sleep × 1.5; on timeout it warns and proceeds (a degraded run just waited, like
the old sleep, instead of desyncing). Log-side siblings: `rig_wait_event` (poll a log for a regex up
to a cap) and `rig_wait_boot` (the client's world-load milestone — far faster than a blind boot sleep).

### KB-16 — Catch a TRANSIENT visual (a sub-second flash) — ring-record, keep the extreme frame — VALIDATED
Don't try to *time* the shot at a sub-second effect (a spell flash) — the log line and the on-screen
flash are only loosely ordered, so no single log-triggered grab is reliable. Instead **ring-record**
the observer's frames (`xwd`, ~0.15 s cadence) from before the action until shortly after its log
proof, defer the CPU-heavy scoring until the window has passed, then keep the frame with the **largest
RMSE vs an idle baseline** — the flash at its observable peak, on whichever try landed. A genuinely
missing effect scores ~0 everywhere and still fails. **General pattern:** to catch a transient, don't
time the shot — ring-record around the event and keep the extreme frame.

### KB-17 — Trust the SERVER's cell-change line over the client's for tight timing — VALIDATED
When both sides log an event, gate a retry on the **server's** line (e.g. `Adding <cell> to Player
<P>`), never the client's own stdout: a headless client's stdout is **block-buffered under
redirection** and can lag many seconds, so a false "did not activate" makes a retry turn the player
*away* from an already-open door. The server's captured line is fresh; the client's is not. (This is
also why you **poll** a logged value rather than single-grepping it — the buffer flushes in batches.)

---

*Add new recipes here as you calibrate them: the recipe, why it works, its confidence, and the dead
ends — especially the dead ends.*
