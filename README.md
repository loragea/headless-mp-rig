# headless-mp-rig

A headless test rig for **OpenMW-multiplayer (TES3MP-lineage)** builds. It boots a **real** dedicated
server and one-to-three **real** game clients under Xvfb, drives them with `xdotool`, and verifies
multiplayer behaviour three ways — server/client **log signatures**, **screenshot** comparison, and
**differential-motion** frame pairs. It turns "two people log in and check the sync by hand" into a
scripted, deterministic, CI-able test.

It exists because the bugs that hurt multiplayer most — *players can't see each other*, *remote
animations don't play*, *a sync packet silently stopped firing*, *damage only applies on the
attacker's client* — only appear with a second real client in view, so a single-process unit test
structurally cannot catch them. This rig puts multiple real clients in one world and asserts what
each one sees.

> Not affiliated with or endorsed by the TES3MP or OpenMW projects. It drives their software from the
> outside (no engine source is included); binary names and paths are configurable, so it works
> against any TES3MP-lineage build.

## Requirements

- Linux with **Xvfb**, **xdotool**, **ImageMagick 7** (`magick`/`import`) and **python3**, plus
  `bash`, `tar`, `procps` (`pgrep`/`pkill`); `shellcheck` for `bin/rig lint` (optional); `unzip` only
  to import zipped server saves; `lua5.1` or `luajit` for the selftest's Lua syntax check (optional).
- A compiled **client + dedicated server** of your OpenMW-MP build, and its **server-side Lua
  scripts** (TES3MP CoreScripts or your fork's).
- A working GL (software `llvmpipe` is fine, just slow).
- For the example: OpenMW's free **example-suite** content
  (`git clone --depth 1 https://gitlab.com/OpenMW/example-suite`).
- Optional: a Release-built MyGUI to shadow a broken distro MyGUI (`RIG_MYGUI_FIXED`;
  `docs/WRITING-SCENARIOS.md` §6, "invisible UI").

## Quickstart

**1. Configure** (2 minutes). Every key is listed and commented in `rig.conf.example`.

```sh
cp rig.conf.example rig.conf
$EDITOR rig.conf      # RIG_BUILD (dir with the client + server binaries and the client's openmw.cfg),
                      # RIG_CLIENT_BIN / RIG_SERVER_BIN if your fork renamed them, RIG_CORESCRIPTS,
                      # RIG_CONTENT_example_DATA = <example-suite>/game_template/data
bin/rig doctor        # every problem names the rig.conf key or the package to fix; exit 0 = ready
```

**2. Run the example** (2-4 minutes on software GL): two real clients join one server on free
content and each sees the other.

```sh
bin/rig run scenarios/example
```

It prints one line per step and ends with `RESULT PASS 0 example …` and exit 0. Everything a run
writes lands in its own directory under `RIG_RUNS` (default `runs/`), printed on the first line; your
build dir and your CoreScripts clone are only read. `bin/rig list` shows the scenarios it finds.

**3. Write your own** scenario: a directory with `scenario.conf` (players, content profile, fixture)
and `steps.sh` (one verb per line). Start from the teaching set, `scenarios/teach-*`: six small
commented scenarios, one verification pattern each (log line, client probe, setup by command, frame
pair, blessed reference frame, extra plugin), listed in `scenarios/README.md`.

```sh
bin/rig new scenarios/local/my-test --content example --players "a b"
cp -r scenarios/example/player scenarios/example/coreScripts-overlay scenarios/example/settings.cfg \
      scenarios/local/my-test/                  # a fixture (returning players a, b) + what the content needs
$EDITOR scenarios/local/my-test/scenario.conf   # OVERLAY=coreScripts-overlay  SETTINGS=settings.cfg  PASSWORDS="a a"
$EDITOR scenarios/local/my-test/steps.sh        # the verb table is at its top
bin/rig lint scenarios/local/my-test            # seconds: conf keys, verbs, arguments, shellcheck
bin/rig run scenarios/local/my-test
```

The three copied items are what the example-suite content needs (its README says why); on your own
content you bring your own fixture (`docs/WRITING-SCENARIOS.md` §1-2). `scenarios/local/` is
gitignored.

**4. On a red run** (exit 1 fail, 2 regression, 3 infrastructure, 4 content missing):

```sh
bin/rig explain latest        # each failing step: its steps.sh line, the log window it searched,
                              # the shot/reference/diff or signature diff to open
bin/rig rerun-failed latest   # run what failed again
bin/rig stats                 # per scenario across all runs: passes, retries, failures, durations,
                              # and whether recent failures are bad luck or a likely regression
```

A run records the host's load next to its verdict (`load.txt`) and never waits for an idle box: a
software-GL test can fail by chance on a busy box, so re-run it (`bin/rig run --retry-failed 1`) and
let `bin/rig stats` show whether a scenario's failure rate went up.

**4b. Bless a reference** for a scenario with a `shot` or `signature` and no reference yet (an
`UNBLESSED` row), or after a verified, intended behaviour change:

```sh
bin/rig calibrate scenarios/local/my-test     # 3 capture runs: per shot the run-to-run spread, a proposed
                                              # tolerance, the recommended frame and a contact sheet
bin/rig bless <calibration.json> scenarios/local/my-test --note "why this frame is right"
```

Open the contact sheets before you bless: blessing is a human decision, and `bin/rig run` never
blesses. Re-blessing is never a response to a failing test (`docs/VERIFICATION.md` §5).

**5. Explore by hand** when you do not yet know how to drive an action headlessly:

```sh
bin/rig up scenarios/example  # boots the server and both clients, logs them in, stays up, prints
                              # each display, pid and log
DISPLAY=:99 xdotool key Return; DISPLAY=:99 import -window root shot.png
bin/rig cmd console a "ModCurrentFatigue -10"   # a console command the server pushes (no kick)
bin/rig cmd probe a nearby    # what a's engine holds (scenarios with PROBE=1)
bin/rig down                  # stops everything up (or a killed run) left running
```

`bin/rig help` lists the commands and `bin/rig help <command>` explains one.

## Layout

```
rig.conf.example     copy to rig.conf; every key, commented: build, scripts, content profiles, runs, displays
bin/rig              the command line: doctor, list, new, lint, run, explain, rerun-failed, stats,
                     calibrate, bless, up, down, cmd
bin/run-example.sh   shorthand for `bin/rig run scenarios/example`
lib/rig.sh           the rig: run dirs, CoreScripts work copy, boot server+clients, load fixtures, drive
                     input, event-gated waits, capture
lib/scenario.sh      the runner: conf parser, verbs, log windows, verdict, run sets (+ selftest)
lib/cli.sh           the authoring and diagnosis subcommands of bin/rig
lib/stats.sh         host load recording (load.txt) and `bin/rig stats` (+ selftest)
lib/calibrate.sh     `bin/rig calibrate` (spread, tolerance, medoid) and `bin/rig bless` (+ selftest)
lib/compare.sh       screenshot regression compare (magick, per-image tolerance) — library + CLI + selftest
lib/logcheck.sh      log event-signature compare (masked, ordered) — library + CLI + selftest
overlay/             the rig's server-side bridge, layered into every CoreScripts work copy: anchor log
                     lines and the setup commands (console, server Lua, save, probe requests)
probe/               the client probe: a read-only Lua player script loaded with PROBE=1 (OpenMW >= 0.48)
templates/scenario/  the scaffold `bin/rig new` copies
scenarios/example/   the worked example: fixture, overlay, references (free example-suite content)
scenarios/teach-*/   the teaching set: one verification pattern per scenario (scenarios/README.md)
docs/                the manuals (below)
```

## Documentation

- **[docs/SCENARIO-FORMAT.md](docs/SCENARIO-FORMAT.md)** — the scenario directory, every
  `scenario.conf` key, every `steps.sh` verb, log windows, exit codes, the run directory and
  `bin/rig stats`, the client
  probe's lines and the server bridge's command files.
- **[docs/WRITING-SCENARIOS.md](docs/WRITING-SCENARIOS.md)** — how to author a test: prepare a start
  state (position players, set spells/gear/skills, edit server save files), the fixture format,
  testing with **real game data** vs free content, avoiding the vanity camera, the action vocabulary,
  and the manual exploration loop.
- **[docs/VERIFICATION.md](docs/VERIFICATION.md)** — the three signal types and **when to use each**
  (log-gated vs static reference image vs dynamic pair), plus the exact ImageMagick metrics, the
  tolerance rule `bin/rig calibrate` applies, freak-frame handling and blessing.
- **[docs/cookbook/](docs/cookbook/)** — the headless-action recipes, one file each: casting, scroll
  timing, camera turns, inventory drag-and-drop, item pickup, finding GUI click coordinates, catching
  a transient visual, photographing a place by hand, and the combat-state confounds that make casts
  "flaky".
- **[docs/FEATURE-TESTS.md](docs/FEATURE-TESTS.md)** — worked patterns for feature guards: **PvP
  melee damage-sync**, **summon lifecycle + caster identity**, **magic-effect identity sync**, and
  **player→player effect sync** — each with its vehicle and its load-bearing assertions.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the rules and how to add a capability or recipe.
CI runs shell lint, the five library selftests and `bin/rig lint` on the example, the teaching set
and a scaffolded scenario; none of it needs a game binary.

## License

MIT — see [LICENSE](LICENSE). Example scenarios use OpenMW's freely-licensed example-suite content.
Anything you author from a commercial game's data (e.g. Morrowind) is derived from that game's
content, is **not** MIT-covered, and should be kept out of a public repo (`scenarios/local/` is
gitignored for exactly this).
