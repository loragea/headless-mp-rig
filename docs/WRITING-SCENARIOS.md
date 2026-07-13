# Writing scenarios

A **scenario** is **saved server-state + scripted choreography**:

- **(a) a fixture** — an authored start-state that returning players resume into (positions,
  inventory, selected spells, nearby NPCs, cell authority), and
- **(b) a choreography** — a script of per-player actions with screenshots and log-checks at fixed
  points.

You resume players into a hand-built situation rather than driving character generation every run,
because a returning load is deterministic (camera mode and saved rotation restore cleanly) while
fresh chargen settles less predictably. This guide covers building the fixture, driving it, and the
environment traps that bite headless runs.

---

## 1. The fixture = six stateful server-state subdirs

A TES3MP-lineage dedicated server keeps its live state under its scripts' `data/` dir in six
subdirs:

```
player/  cell/  world/  map/  recordstore/  custom/
```

A **fixture is exactly those six subdirs** — nothing else. It is *not* the non-stateful top-level
files that also sit in a server `data/` dir: `banlist.json` (irrelevant) and `requiredDataFiles.json`
(the rig writes this per-run to match the client content list — see §4). `player/*.json` are the
per-player saves; `cell/*.json` are per-cell object state (including NPC/creature stats); `world/`
holds global variables.

The rig's fixture calls:

- **`rig_load_scenario <dir>`** — restores the six subdirs **fresh from the fixture every run**
  (it `rm -rf`s each first), so every run starts byte-identical **and** whatever the previous run
  left is cleared (stale players/cells don't leak).
- **`rig_import_fixture <src> <dir>`** — imports a freshly-authored server `data/` dir (or a `.zip`
  of one) into a fixture, copying only the six subdirs and **replacing** them (so re-importing a new
  authoring cleanly drops players you removed).
- **`rig_clear_state`** — empties the six subdirs for a run that starts from a blank world.

A fixture can be a **superset** that several scenarios share (e.g. one save holding players for two
different choreographies). An unconnected player in the fixture is inert — a choreography only
`rig_login`s the players it uses.

---

## 2. Preparing a start state

Division of labour that works: **a human authors intent + start state** (things that need game
knowledge and a person at the keyboard); **the script does the mechanical driving + verification.**

### 2a. Author by playing, then hand off the save

The reliable way to build a fixture is to **play into it** with a real client:

1. Run a **portable/release build** of your client against a local server — it feels like
   single-player MP.
2. Drive the world to the situation you want: walk each player to its position and facing, put the
   right items in inventory, select the spell/scroll on a quick-key, get the right NPCs nearby.
3. **Save**, then hand the server's `data/` dir (or a `.zip` of it) to `rig_import_fixture`.
4. Convention: **player password = player name** (`a`/`a`, `b`/`b`, …) so the rig can log them in.

Then commit the fixture. (Fixtures derived from a commercial game's data are game-content — keep them
in `scenarios/local/`, which is gitignored, not in a public repo.)

### 2b. Adjust spells / gear / skills / stats in the save files

Anything the engine reads from the save snapshot you can set **directly in the fixture JSON**, which
is often faster and more precise than doing it in-game — and some things (exact stat values) are only
practical to set this way:

- **Skills / attributes / stats** — edit the player's `player/<name>.json` under
  `skills`/`attributes`/`stats` (e.g. raise a weapon skill to 100 so a swing always lands, or a
  magic skill so a spell never fizzles). The server honours the snapshot; no recompute.
- **NPC / creature health and stats** — edit the object in the relevant `cell/<cell>.json` under
  `objectData.<refnum>.stats.health{Base,Current,Modified}`. Example use: bump a target NPC's health
  so a test scroll can't accidentally kill it mid-assertion (see COOKBOOK KB-14).
- **Inventory + quick-keys** — put the test item in the player's inventory and bind it to a quick-key
  in the save, so the choreography can equip-and-use it with one key.

Prefer putting **geometry** (who faces whom, who stands where) in the fixture rather than in the
script: a receiver already aimed at a dropped item picks it up with a single activate; a caster
already facing its target hits with no calibrated turn. Author the aim once; the script stays simple.

**Server-side adjustment at runtime (the untouched-fixture pattern).** When a test needs to *set up*
state without editing the blessed fixture, do it from a one-off server-script chat command that
modifies the caller via the CoreScripts API (max a skill, grant a scroll + quick-key, bulk health)
and call it from the choreography. `rig_load_scenario` clears whatever the run saved, so the blessed
fixture stays pristine. This is how the feature tests in `docs/FEATURE-TESTS.md` provision combat
stats and summon scrolls.

---

## 3. Co-location and cell authority

Put co-location **in the fixture**, not a runtime hook: pre-place the players (a CoreScripts teleport
during authoring) so each phase starts with the right cell authority and facing. **Login order sets
cell authority** — the first player into a cell owns it — so choreograph the authority you want by
logging players in in the right order. (If your server uses instanced spawns, disable that for
co-located scenarios or each player lands in a separate instance of the cell.)

---

## 4. Testing with real game data (vs free content)

The rig runs on either free content or a commercial game's data; the difference is the content block
and the required-data-files list.

### Free content (redistributable, no game needed)

OpenMW's **example-suite** (`git clone --depth 1 https://gitlab.com/OpenMW/example-suite`) ships a
tiny free `template.omwgame`. It's enough for connection/visibility/movement tests:

```sh
rig_set_required_datafiles template.omwgame   # prepends builtin.omwscripts for you (client entry 0)
rig_add_content example "data=$EXAMPLE_SUITE" "content=template.omwgame"
```

`rig_set_required_datafiles` **already prepends `builtin.omwscripts`** (the ≥0.48 client auto-loads
it as content entry 0), so pass only the real content files — here just `template.omwgame`. Passing
`builtin.omwscripts` explicitly duplicates it, yielding a server list of `[builtin, builtin]` that the
client (`[builtin, template.omwgame]`) is index-shift-rejected against ("template.omwgame is past the
number of plugins used by the server") — disconnect before login.

### Real game data (e.g. Morrowind)

Real data exercises the game the way players do — actual cells, NPCs, doors, items, spells. Two
must-get-right details:

1. **BSA archives are not auto-loaded.** OpenMW does **not** read `.bsa` from a data dir; you must
   pass each as a `fallback-archive=` line or the client boots with no meshes/textures/GUI and dies:

   ```sh
   rig_add_content mw "data=$MW_DATA" \
       "fallback-archive=Morrowind.bsa" "fallback-archive=Tribunal.bsa" "fallback-archive=Bloodmoon.bsa" \
       "content=Morrowind.esm" "content=Tribunal.esm" "content=Bloodmoon.esm"
   ```

2. **`requiredDataFiles.json` must match the client's content list ENTRY-FOR-ENTRY**, or every client
   is rejected with an index-shifted mismatch ("X is past the number of plugins used by the server")
   and **disconnects before login** — so the player never reaches the world and every in-world assert
   silently fails. `rig_set_required_datafiles` writes it for you (empty checksum lists = accept any
   build):

   ```sh
   rig_set_required_datafiles Morrowind.esm Tribunal.esm Bloodmoon.esm
   ```

   **`builtin.omwscripts` gotcha:** modern clients auto-load `builtin.omwscripts` as content **entry
   0**, so the server's required list must put it **first** — `rig_set_required_datafiles` prepends it
   by default. For an *older* client that does not auto-load it, set `RIG_RDF_BUILTIN=0` to omit the
   prepend (otherwise the list is index-shift-rejected).

Pick a start cell **off** the game's default spawn cell if it has hazards — e.g. Morrowind's census
cell has invisible collision boxes and a hostile mudcrab that shove players ~1400 units and wreck
determinism.

---

## 5. Avoiding the vanity camera (the #1 headless trap)

After `fVanityDelay` (**30 s**) of no input, OpenMW swings into the **vanity (idle) camera**: a
slowly-orbiting third-person view that **also hides the crosshair**. This is the long-standing
"camera is non-deterministic" red herring — it is not; the camera is fully deterministic, the client
just sat idle past 30 s (easy to do across boot + the sleeps in a choreography; a returning player can
even enter the world already expired, because typing at the connect screen doesn't reset the timer).
While vanity is active the centre-screen ray is wrong, so **activate/pick-up silently misses** and
screenshots are re-framed.

**Fix:** call **`rig_start_idle_wiggler` once, after your players are in-world.** It nudges the mouse
1px-and-back on every booted display every `RIG_WIGGLE_INTERVAL` (default 20 s, which must stay
`< 30 s`), firing immediately on start. The nudge direction alternates so its injected yaw cancels
over pairs (net ~0 drift) and returns the cursor to screen-centre, disturbing neither gameplay aim
nor a mousemove-then-click GUI flow. With it running, every client stays in its real first-person
camera for the whole run. **If you ever see an unexpected third-person / no-crosshair frame, it's
vanity — wiggle, don't theorise.**

---

## 6. One Xvfb display per client

Each client gets its **own** Xvfb display (`:99`/`:100`/`:101`), not a shared one. A shared Xvfb
fails twice: with no window manager `xdotool windowactivate` errors ("no `_NET_ACTIVE_WINDOW`"), and
overlapping windows mean the occluded one captures as garbage (X11 has no backing store without a
compositor). One window per display ⇒ input and `import` target it by setting `DISPLAY=` with **no
focus call at all**. Multi-client visibility is a *network* sync (all clients on one server), so
separate displays don't affect what the test measures. All displays use the **same** screen size, so
the window-geometry math (centre `640,360` of an 800×600 SDL-centred window in 1280×720) holds on
each.

**Invisible UI:** if dialogs are invisible but still respond to clicks, your distro's MyGUI was built
without `CMAKE_BUILD_TYPE` (Debian's `libmyguiengine3debian1` renders nothing). Point
`RIG_MYGUI_FIXED` at a Release-built MyGUI under the same soname; the rig `LD_LIBRARY_PATH`-shadows
it. Headless tiers can't see this bug — only a human or a screenshot catches it.

**Isolated profiles are mandatory.** A shared `~/.config/openmw` carries another engine version's
`input_v3.xml`/`settings.cfg`/`shaders.yaml`; sharing it breaks this build's bindings and shaders.
The rig runs each client under an isolated `XDG_CONFIG_HOME`/`XDG_DATA_HOME` and wipes it each run.

---

## 7. Action vocabulary — keep each step atomic

Actions must be drivable headlessly and verifiable, so keep them **simple and atomic** and compose
complexity from *sequences*, not fancy single actions.

- **Tier A — trivial, always reliable** (keyboard-driven, deterministic): login/logout, movement taps
  (`rig_tap w`), stance toggles (`F` weapon, `R` spell), quick-keys (`1`–`0`), activate (`space`),
  chat commands (`rig_chat_command`).
- **Tier B — needs a known recipe** (in COOKBOOK, reliable once calibrated): casting (synthetic LMB),
  scroll casting (quick-key + read-parchment), hiding the chat/welcome window, inventory open,
  dropping an item into the world, picking a world item up.
- **Tier C — calibration-sensitive** (drive via the exploration loop, expect iteration): precise
  camera turns, timing a screenshot to a sub-second visual, anything mouse-*aimed* in gameplay.

Rule of thumb: if an action is "press key / hold key / type text / activate", it's Tier A–B and
cheap. If it needs *aiming* or *frame-timing*, it's Tier C — still doable, but budget a calibration
pass and **record the result in COOKBOOK** so it's Tier B next time.

---

## 8. The manual exploration loop (for Tier-C / unknown actions)

When an action's headless implementation is unknown or flaky, **don't guess and bake it into the
scenario** — isolate it:

1. Boot a single long-lived client into the relevant fixture (`templates/explore-client.sh`): one
   ~40 s boot, many fast tries, far cheaper than re-running the whole scenario per attempt.
2. **One action → screenshot → read the screenshot → check the server/client log → adjust → repeat.**
   The screenshot catches the visual; the log catches the packet (the deterministic signal).
3. **Vary one thing at a time** (hold-time, key vs mouse, with/without a preceding state change), and
   beware game-logic confounds: a "flaky" action is often a legitimate in-game failure (a skill-based
   cast chance, a resource cost, a modal window) that headless work hides. Rule those out before
   blaming the input. When in doubt, ask someone with game knowledge — it resolves these instantly.
4. **Record the outcome in COOKBOOK** — what worked, what didn't, and *why*, including the dead ends.
   That record is the point: it turns a Tier-C action into a Tier-B recipe.

---

## 9. Determinism caveats worth knowing up front

- **Always resume from a save; never run chargen mid-scenario** (returning-load is deterministic;
  chargen settles less predictably). If you must drive chargen, screen-stability-gate every dialog
  (see COOKBOOK KB-15) and keep a fresh-client retry.
- **Suppress vanity for the whole run** (§5) — it is the usual cause of "camera non-determinism".
- **Interior light sources flicker by design** in some games (Morrowind), which makes full-frame
  perceptual-hash screenshots bimodal — prefer stable-lighting venues for full-frame STABLE shots, or
  crop the shot to the GUI element it actually asserts (see VERIFICATION and COOKBOOK KB-19).
