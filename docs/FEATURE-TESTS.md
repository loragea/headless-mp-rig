# Feature-specific tests

Patterns for building a **targeted feature guard** — a deterministic headless reproduction that
proves one multiplayer property holds (and reddens when a change breaks it). Start from
`templates/repro-template.sh`. These are regression guards, not visual gates: **assert the
authoritative state change from the logs / saves**, not a screenshot.

## The shared pattern

1. **Provision state server-side, leaving the fixture untouched.** A one-off chat command (wired from
   `CoreScripts/scripts/customScripts.lua`) modifies the caller via the CoreScripts API — max/adjust
   skills, attributes, health; grant a scroll + quick-key; spawn an actor. Because `rig_load_scenario`
   clears whatever a run saves, the blessed fixture stays pristine. This makes the outcome
   **deterministic** (a maxed weapon-skill + agility vs a low-evasion victim clamps hit chance to
   100%; a granted scroll always casts).
2. **Drive the real action** from a real client (attack input, cast recipe from COOKBOOK).
3. **Assert the property where it is AUTHORITATIVE** — the victim's synced/persisted state, the effect
   id read off the wire, the despawn origin — not just "something happened". The difference between a
   real guard and a weak one is asserting the *authoritative* side.
4. **Poll logged values, never single-grep them** — the server's captured stdout is block-buffered, so
   an immediate grep races the unflushed buffer and reads empty (a false fail). `rig_wait_event`
   already polls; read your own logged values the same way.

Two engine facts that shape these tests:
- **Login order sets cell authority** (first player into a cell owns it) — choreograph the
  authority/observer roles by login order.
- **Identity rarely crosses the wire as a raw actor id** — caster/attacker/summoner identity travels
  as a player `guid` or an actor `(refId, refNum, mpNum)` and is resolved to a local id on receipt. So
  a guard for "identity survived sync" must read the *remote observer's* resolved attribution, not the
  caster's own client.

---

## 1. PvP melee damage-sync

**Property:** a hit from one player applies damage on the **victim's** client and syncs back — not
"damage only on the attacker's client" (the classic desync).

- **Vehicle:** two co-located players — attacker `f` wielding a real weapon and facing victim `d` in
  the fixture. A `/combatprep` chat command maxes the caller's weapon skill + Agility + Luck + Strength
  and full fatigue, drops every other player's Agility/Luck, and **bulks their health** so a clean hit
  doesn't one-shot them mid-assert. Wielding a **real weapon** (not fists) drives the weapon-id `onHit`
  signature.
- **Attack input:** draw the weapon (`F`), then `xdotool mousedown 1; sleep 0.7; mouseup 1` (charge +
  release). A short forward `w` tap between swings closes melee reach. Hide chat first (KB-4) so the
  swing click isn't eaten.
- **Health readout must be chat-independent.** A `/hpreport`-style command sent *after* hiding chat
  never dispatches (a hidden chat window won't open on the say-key). Instead log the pre-combat
  baseline inside `/combatprep` (chat still visible) and register an `OnObjectHit` handler that logs
  every player's current/base health after each hit — no post-attack chat.
- **Assertions (all log/state-gated):** server `Accepted ObjectHit from f … for players: d` (attacker
  emitted the hit); `d`'s **client** log `Processing attack from …` (the victim receive/apply side, at
  VERBOSE — printed at the default client logLevel); `d`'s server-synced health **drops** across the
  assault; and `d`'s saved `player/d.json` shows `healthCurrent < healthBase` after logout (persisted,
  victim-authoritative). `f`'s health unchanged, no death.
- **Why the victim's synced health is load-bearing:** a player's health is authoritative on that
  player's own client; the server value is synced *from* the victim and relayed identically to every
  loaded client, so it's exactly what the attacker's client sees too. Reading it (plus the persisted
  json) proves the victim applied the damage — the thing a desync would break.

## 2. Summon lifecycle + caster identity

**Property:** a summoned creature stays attributed to its caster **on a remote client** and despawns
when the caster's effect ends — not merely "a summon appeared".

- **Vehicle:** grant a cast-once summon scroll + quick-key server-side (`inventoryHelper.addItem` +
  `LoadItemChanges` + a `quickKeys` entry + `LoadQuickKeys`), so the fixture is untouched. Cast with
  the KB-2 out-of-combat recipe. Choose the caster/observer roles by login order (log the observer in
  first so it owns cell authority).
- **Assertions:** the server's `used inventory item <scroll>` line, then the summon chain
  (`ID_OBJECT_SPAWN`, both clients `setting summoned creatureActorId`, `ID_OBJECT_DELETE` at effect
  end, no creature left in the cell json). Plus the two identity guards:
  - **Remote-observer attribution.** On the observer's client the summon's master resolves to the
    *caster's* remote player record (a `$dynamic…` refId), so the observer logs `Actor has master:
    $dynamic…` while the caster's own client logs `Actor has master: player`. Asserting the `$dynamic`
    master on the observer proves cross-client caster linkage — distinguishing real sync from
    "attributed on the caster's client only".
  - **Summoner-driven despawn.** The effect-end `ID_OBJECT_DELETE` must arrive **from the caster** (the
    summon effect lives on the caster's LocalPlayer; its expiry drives the delete). A delete *from the
    summoner* proves the whole caster→summon→despawn chain held end-to-end.
- **Dead end (don't):** pushing a summon *active spell* from the server instead of casting reaches the
  client but the active **expires client-side within a second** (the client sends a removal, relayed
  before the other clients apply), so no summon happens anywhere. Use a real cast, or a non-summon
  effect for a pushed-active test.

## 3. Magic-effect identity sync (player→player)

**Property:** the **correct** effect (right effect id + arg) applies on the victim and persists — a
guard that asserting only the spell *name* would miss (a migration that garbles the effect id/arg
still logs the name).

- **Vehicle:** the caster carries a **Target-range** effect scroll (e.g. a Drain-Attribute scroll) on
  a quick-key and faces the victim in the fixture. Cast the KB-2 out-of-combat recipe at the victim.
  **Prime the quick-key first** — a scroll quick-key sends an item-use packet that waits for server
  approval, so open+close the inventory once and settle before the cast, else early-after-login the
  round-trip isn't ready and the click falls through to a plain activate.
- **Assertions:**
  - **Off the wire:** a server-side `OnPlayerSpellsActive` handler logs the per-effect id/arg from the
    victim's incoming `ID_PLAYER_SPELLS_ACTIVE` packet — assert the exact id **and** arg (e.g.
    DrainAttribute + Agility). (Capture magnitude but don't gate it if the build syncs it as a known
    quirk — gating a pre-existing quirk reddens the baseline.)
  - **Persisted, victim-authoritative:** after logout the victim's `player/<v>.json` persists the
    active spell's effect with the same id + arg (round-tripped victim→server→save).

## 4. Player→player effect sync (the log-only variant)

**Property:** a Target-range effect fired by one player lands and applies on another — the cross-client
active-effect surface — with **no screenshot needed** (every link is logged).

- **Vehicle:** a Target-range scroll (a drain, which can't kill) ×N on a quick-key; the caster faces
  the victim in the fixture so the projectile hits dead-centre first try (carry spares — a
  fired-but-missed Target projectile is consumed).
- **Assertions (full chain, all logged):** `<caster> used inventory item <scroll>` → `Accepted
  ObjectHit from <caster> … for players: <victim>` (the projectile hit) → `Adding instance of active
  spell <scroll> to <victim>` (the effect applied) → the hit-sound relay (`played sound …`). If a
  relay line has two engine code paths and only one emits it (an internal race), **don't assert that
  line** — assert the state change and cover the relay layer through a vehicle that deterministically
  takes the emitting path.

---

## Building your own

1. Name the property and how it could *silently* fail (what a weak "did it happen?" assert would miss).
2. Pick a deterministic vehicle (server-granted stats/scroll) so the action can't legitimately fizzle.
3. Assert the **authoritative** side — the victim's synced/persisted state, the remote observer's
   resolved attribution, the wire-read id — not the actor's own client.
4. Establish the guard on a **known-good build first** (so a later red is attributable to the change
   under test, not a pre-existing gap), and record that baseline result in the test's header.
