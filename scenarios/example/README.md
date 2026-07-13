# scenarios/example — runnable free-content multiplayer example

A **genuinely runnable** two-client multiplayer example that runs entirely on OpenMW's
freely-licensed **example-suite** content (`template.omwgame`) — **no Morrowind or other commercial
data required**. It demonstrates the toolkit's core value: **two real TES3MP clients in one world,
with cross-client sync verified from the logs.**

Run it:

```sh
# long run (server + 2 client boots on software GL) — drive it via bg.sh so it isn't killed
tools/bg.sh start bin/run-example.sh
tools/bg.sh wait            # repeat while it prints 124
```

`bin/run-example.sh` exits **0 (green)** when every assertion passes, **non-zero (red)** otherwise.

## What it asserts (every assertion backed by a real log line)

The deterministic PASS/FAIL gate is **log-based** (`rig_wait_event` inline asserts + a blessed
`lib/logcheck.sh` server-log signature). In one run:

1. **Both clients are admitted** — server logs `Client was allowed to connect` ×2.
2. **Both players are created** server-side — `Creating new player` ×2.
3. **The example-suite compat shim ran** — `[example-suite-compat] filled …` (see *Quirks* below); its
   absence means the server would have crashed on non-Morrowind content.
4. **Cell authority** — the first player in (`a`) owns the shared cell: `Authority of cell 0, -7 is now a`.
5. **Mutual cross-client visibility** (the bug class this whole rig exists to catch):
   - client `a`'s log: `b (…) has joined the server` **and** `DedicatedPlayer b` — a sees b;
   - client `b`'s log: `DedicatedPlayer a` — b sees a.
6. **Stability tripwires** — neither client logs `committed suicide` (the water-breathing fixture
   holds — see *Quirks*), and the server log contains no `script error` / `Server crash` / Lua error.

The blessed server-log signature lives in `reference-logs/example-server.events` (6 normalized events).
A signature move is a **regression** → investigate, or re-bless with `UPDATE_REFS=1 bin/run-example.sh`.

## Screenshot signals demonstrated

The example also exercises **both screenshot verification modes** (`docs/VERIFICATION.md`) — their
*feature* value here is incidental; the point is to show the mechanics end-to-end in a runnable scenario:

- **DYNAMIC pair (must DIFFER).** On client `a`'s display, one frame is captured **before** `b` logs in
  (`10-a-before-b` — `a` alone, one minimap marker) and one **after** (`11-a-after-b` — `b`'s avatar now
  in view, two markers). The gate is *motion present* — `RMSE(10,11) ≥ 0.02` (measured ~0.081) — the
  inverse of a static match. A sync bug that left `b` invisible to `a` would leave the two frames
  near-identical and **fail** this. The pair is never blessed; only its mutual delta is gated, in-script.
- **STATIC blessed frame (must MATCH).** On client `b`'s display, `b`'s minimap is cropped to a stable
  region (`20-b-minimap` — showing both player markers) and compared to a blessed reference within a
  per-image tolerance (`reference-images/manifest.tsv`: `RMSE ≤ 0.03`, measured ~0.008–0.012). Cropping
  to a **stable GUI region** is the KB-19 convention: the full 3D frame (animating water, a T-posed
  avatar) is too variable to bless, but the minimap crop is not. Re-bless with
  `UPDATE_REFS=1 bin/run-example.sh` (rewrites `reference-images/20-b-minimap.png`).

Adjust the minimap crop for a different resolution via `CROP_MINIMAP` (default `88x84+950+576`, for the
rig's 1280×720 screen), and the dynamic floor via `DYN_FLOOR`.

## The fixture

`player/a.json` + `player/b.json` — two **returning** players (password = `a` for both), co-located in
exterior cell `0, -7`, ~256 units apart. The scenario **resumes** them (no character generation — see
below). The other four stateful subdirs (`cell/ world/ map/ recordstore/ custom/`) are empty. The
client `[Models]` remap it needs is `settings.cfg` (seeded into each client profile via
`RIG_SETTINGS_SRC`). The compat overlay the server needs is `coreScripts-overlay/` (see *Quirks*).

### How the fixture was authored
Because chargen cannot complete on example-suite (below), the saves were **not** produced by playing
chargen. A one-shot authoring hook (`OnGUIAction`/REGISTER) synthesized a complete, returning-capable
save from a freshly *registered* account (which already has a valid salted password hash), capturing
the real spawned cell, then setting race/stats and a permanent water-breathing effect. `b.json` is
`a.json` with `login.name = "b"` and an offset position, **reusing a's login block** so both log in
with password `a`. Timestamps/IPs were zeroed for portability.

## Example-suite quirks this example had to work around

These are properties of the free content, documented so the next person doesn't re-discover them:

- **Content wiring:** the client content list is `[builtin.omwscripts, template.omwgame]`.
  `rig_set_required_datafiles template.omwgame` is correct — it **prepends** `builtin.omwscripts`
  itself; passing `builtin.omwscripts` explicitly duplicates it and the client is index-shift-rejected
  before login.
- **Missing skeleton:** `template.omwgame` has no `meshes/base_anim.nif`; the engine looks for it and
  dies ("Failed to start new game") unless `settings.cfg`'s `[Models]` block remaps `baseanim`/
  `xbaseanim`/… to `meshes/BasicPlayer.dae`. That `settings.cfg` ships here and is seeded per client.
- **Stock CoreScripts assume Morrowind:** `clientVariableScopes.globals` is only populated inside
  `if clientDataFiles contains Morrowind.esm`, so on example-suite it stays `{}` and the server
  **crashes** on the first player connect (`logicHandler.lua:403: pairs(nil)`). The
  `coreScripts-overlay/` compat shim fills those categories with empty tables on `OnServerPostInit`
  (additive — a no-op on real Morrowind). The runner applies it to a throwaway CoreScripts work-copy;
  the shared clone is never modified.
- **No classes or birthsigns ⇒ chargen cannot complete.** `template.omwgame` has no `CLAS` or `BSGN`
  records, so TES3MP's character generation dead-ends: "Pick from Class list" has an empty list (OK
  disabled), "Generate Class" produces a stock class the data lacks (`Error in frame: Class 'Warrior'
  not found`), and the birthsign list is empty (OK disabled). That is why the scenario resumes a
  fixture instead of driving chargen every run.
- **The world is entirely underwater.** With no landscape data, exterior cells are a flat grid ~2048
  units below the water plane, so a plain spawn **drowns** in a death/revive loop (non-deterministic
  revive locations). The fixture players carry a **permanent water-breathing** active effect (magic
  effect id 0) and rest on the seafloor — deterministic, zero deaths.

## Limitations / what this does NOT cover

- **No blessed screenshot.** The deterministic proof is log-based. The run still captures a best-effort
  frame (`50-a-sees-b.png`) as an artifact, but the all-underwater template makes a stable,
  avatar-framed "a sees b" shot a calibration exercise of low added value over the log gate and the
  in-frame minimap markers (each client's minimap shows the other player's marker). To bless one after
  calibrating: `UPDATE_REFS=1 BLESS_SHOT=1 bin/run-example.sh`.
- **Minimal choreography.** example-suite is a near-empty template — this proves connection, creation,
  cell authority, and mutual visibility (the sync core), not movement/combat/inventory choreography,
  which need richer content.
- **`ID_PLAYER_MAP` never fires** for these returning players on example-suite, so the run gates client
  readiness on connect + a world-load settle rather than the usual `rig_wait_boot` milestone.
