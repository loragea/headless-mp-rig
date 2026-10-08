# scenarios/example — runnable free-content multiplayer example

A **genuinely runnable** two-client multiplayer example that runs entirely on OpenMW's
freely-licensed **example-suite** content (`template.omwgame`) — **no Morrowind or other commercial
data required**. It demonstrates the toolkit's core value: **two real TES3MP clients in one world,
with cross-client sync verified from the logs.**

Run it:

```sh
bin/rig run scenarios/example          # a few minutes on software GL
```

The runner exits **0** when every step passes (codes: `docs/SCENARIO-FORMAT.md` §4.1). The run
directory (`$RIG_RUNS/<stamp>-example/example/`) holds `steps.tsv` (one row per step, with its
`steps.sh` line), `run.log`, both client logs, the server log and the shots.

## What it asserts

The choreography is `steps.sh`; the metadata (players, passwords, content profile, overlay,
signature vocabulary) is `scenario.conf`. In one run:

1. **Cell authority** — right after `login a`, the server logs `Authority of cell 0, -7 is now a`
   (the first player in owns the shared cell).
2. **Mutual cross-client visibility** (the bug class this whole rig exists to catch): right after
   `login b`, client `a`'s log names `DedicatedPlayer b` and `b (N) has joined the server`, and
   client `b`'s log names `DedicatedPlayer a`.
3. **Both clients are admitted** — server logs `Client was allowed to connect` ×2.
4. **Nobody drowned** — neither client log has `committed suicide` (the water-breathing fixture
   holds).
5. **a's engine holds b** (the client probe, `PROBE=1`) — `probe a nearby` lists an actor named `b`
   within 400 units of `a` (the fixture puts them ~256 apart). Its `anim` field is not asserted:
   b's avatar loads as the model in some runs (`anim=idle`) and as the missing-mesh placeholder in
   others (`anim=none`), see below.
6. **A server-pushed console command runs on a, and nobody is kicked** — `console a
   "ModCurrentFatigue -50"` goes through the rig's server bridge; the server logs `Accepted
   ConsoleCommand from a` for the client's echo (an unqueued command is rejected and the client
   kicked, cookbook KB-21), and two `probe a stats` requests around it read a's fatigue drop by 50
   (`assert probe-delta a stats fat '<' -20`).
7. **No server error** — `assert absent server "$RIG_TRIPWIRES"`.
8. **Server-log signature** — `reference-logs/example-server.events` (6 normalized events: both
   connects, both player creations, the compat shim's line, the authority line). A moved signature is
   a `REGRESSION` (exit 2).

`login` itself fails the run as `INFRA` unless the server logs `[rig-bridge] player <name> in`.
The bridge and probe lines are outside the signature vocabulary, so they leave the signature
unchanged.

## Screenshot signals demonstrated

- **DYNAMIC pair (must DIFFER).** On client `a`'s display, the spot in front of `a` where `b` will
  stand (crop `240x300+520+340`) is captured before `b` logs in (`10-a-before-b`) and after
  (`11-a-after-b`). `pair` gates *motion present*: `RMSE ≥ 0.005`. Measured: 0 without `b`, ~0.017
  when `b` renders as the T-posed model, ~0.06 when it renders as the missing-mesh placeholder (both
  occur). A sync bug that left `b` invisible to `a` leaves the two crops identical. Pair inputs need
  no reference.
- **STABLE blessed frame (must MATCH).** On client `b`'s display, the minimap cropped to
  `88x84+950+576` (`20-b-minimap`, both player markers) is compared to
  `reference-images/20-b-minimap.png` within the manifest tolerance (`RMSE ≤ 0.03`, measured
  ~0.003–0.012). Cropping to a **stable GUI region** follows cookbook recipe
  `KB-19-phash-bimodal-crop-gui-rmse`: the full 3D frame (animating water, a placeholder avatar) is
  too variable to bless, but the minimap crop is not.

Re-blessing is a human decision, made only after a verified, intended behaviour change:
`bin/rig calibrate scenarios/example`, review its contact sheet, then
`bin/rig bless <calibration.json> scenarios/example <name> --replace --note "<why>"`, and commit the
written files (docs/VERIFICATION.md §5).

## The fixture

`player/a.json` + `player/b.json` — two **returning** players (password = `a` for both), co-located in
exterior cell `0, -7`, ~256 units apart. The scenario **resumes** them (no character generation — see
below). The other four stateful subdirs (`cell/ world/ map/ recordstore/ custom/`) are empty. The
client `[Models]` remap it needs is `settings.cfg` (`SETTINGS=`, seeded into each client profile).
The compat overlay the server needs is `coreScripts-overlay/` (`OVERLAY=`, see *Quirks*).

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
- **A client idling at the name box drowns.** Before login the client's placeholder character also sits
  underwater; about 45 s after the client starts it dies, and a player who logs in after that resumes
  at a random revive spot. `steps.sh` therefore boots `b` only after `a`'s first frame, so `b` logs
  in ~25 s after its client starts.
- **The world is entirely underwater.** With no landscape data, exterior cells are a flat grid ~2048
  units below the water plane, so a plain spawn **drowns** in a death/revive loop (non-deterministic
  revive locations). The fixture players carry a **permanent water-breathing** active effect (magic
  effect id 0) and rest on the seafloor — deterministic, zero deaths.

## Limitations / what this does NOT cover

- **Minimal choreography.** example-suite is a near-empty template — this proves connection, creation,
  cell authority, and mutual visibility (the sync core), not movement/combat/inventory choreography,
  which need richer content.
- **`ID_PLAYER_MAP` never fires** for these returning players on example-suite, so `boot` takes the
  client's first settled frame (~16 s after start) as its boot milestone.
