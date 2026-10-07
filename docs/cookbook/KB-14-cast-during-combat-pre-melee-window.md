# KB-14-cast-during-combat-pre-melee-window — A cast during combat fails intermittently: cast in the pre-melee window
Read when: a cast made while an NPC attacks the caster passes on some runs and fails on others.

**Confidence: VALIDATED** (the hardening notes at the end: **THEORY**)

Casting a teleport or effect scroll while the caster is being hit fails intermittently for two
vanilla reasons, neither an input bug:

1. **An over-damaging scroll kills the target → the caster drops out of combat → the *next* cast
   takes the out-of-combat path** (read-parchment,
   [KB-2-scroll-quick-key-read-parchment](KB-2-scroll-quick-key-read-parchment.md)) instead of the
   in-combat direct cast. Tell: an `OnActorDeath` / `deathReason: killed by player` line. Fix: keep
   the target's HP above the scroll's maximum total damage (raise
   `stats.health{Base,Current,Modified}` for the actor in the fixture's cell JSON; the server is
   authoritative and the engine honours the snapshot), or use a weaker scroll.
2. **A melee hit landing mid-cast interrupts it.** The use initiates (`OnPlayerItemUse`) but never
   completes: no inventory REMOVE (the scroll is not consumed), no effect sound, no active-spell line,
   no teleport. Tell: diff a passing and a failing server log around the use; the failing one has a
   burst of `ID_OBJECT_HIT` on the caster and lacks the completion chain. Fix: cast in the
   **pre-melee window**.

**The pre-melee window's width is a property of the load profile, not the NPC.** Measure it in the
server log (the triggering hit → the first `ObjectHit … for players: <caster>`), and **re-measure
after any change to the scenario's waits**: making the run faster moves where fixed sleeps land in
the window. Make the window reliable:
- **Poll for hostility, don't blanket-sleep.** Replace a "let combat start" sleep with a tight poll
  (≤0.2 s steps) for the triggering hit's log line, so the approach time isn't spent before you cast.
- **Equip the scroll early**, while the NPC approaches.
- If a motion pair witnesses the approach, take t0 before the trigger and poll for t1
  ([KB-20-motion-poll-keep-clearing-frame](KB-20-motion-poll-keep-clearing-frame.md)), then cast
  immediately.
- **Retry on an incomplete cast.** An interrupted cast doesn't consume the scroll, so carry spares and
  re-key, gated on the server's completion line (a teleport's cell-change line, which a retry cannot
  fake). A wandering NPC's distance at the cast instant is variance no window removes; the retry turns
  it from a flake into a logged recast.
- To catch the cast's visual effect, ring-record rather than timing the shot
  ([KB-16-ring-record-transient-visuals](KB-16-ring-record-transient-visuals.md)).

**Hardening (THEORY).** A retry that fires although the first cast already succeeded re-equips the
scroll out of combat and opens the read-parchment, which can survive a teleport and sit over the
arrival frame. Gate the retry on evidence that the first cast *failed* (no completion line yet), and
dismiss any open GUI before grabbing an arrival frame.

**General lesson (extends
[KB-5-rule-out-game-logic-confounds](KB-5-rule-out-game-logic-confounds.md)):** a "flaky cast" is
rarely the synthetic input. Look at the combat state at the cast instant; death and hit-interrupt
both confound the cast through combat, not through the click.
