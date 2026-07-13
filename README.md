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

- Linux with **Xvfb**, **xdotool**, and **ImageMagick** (`magick`/`import`), plus `bash`, `unzip`.
- A compiled **client + dedicated server** of your OpenMW-MP build, and its **server-side Lua
  scripts** (TES3MP CoreScripts or your fork's).
- For the graphics gate: a working GL (software `llvmpipe` is fine, just slow).
- Optional but recommended: a Release-built MyGUI to shadow a broken distro MyGUI (see
  `docs/WRITING-SCENARIOS.md` → "invisible UI").

## Quickstart

```sh
cp rig.conf.example rig.conf      # then edit: point RIG_BUILD at your build, set the binary names
$EDITOR rig.conf

# sanity-check the verification libs with no game data needed:
lib/compare.sh selftest
lib/logcheck.sh selftest

# run the worked example — two real clients in one world on FREE example-suite content, cross-client
# sync asserted from the logs (green exit 0 / red non-zero). A full run takes a few minutes on
# software GL; run it directly (or under your CI's long-job runner). See scenarios/example/README.md.
bin/run-example.sh

# author + run a targeted feature test (see docs/FEATURE-TESTS.md):
cp templates/repro-template.sh my-test.sh
$EDITOR my-test.sh                # fill in the four TODO blocks
./my-test.sh

# probe an unknown headless action interactively:
FIXTURE=scenarios/example PLAYER=a templates/explore-client.sh   # boots a client and stays up
```

## Layout

```
rig.conf.example     copy to rig.conf; sets binary names, build dir, scripts dir, displays, timeouts
lib/rig.sh           the rig: boot server+clients, load fixtures, drive input, event-gated waits, capture
lib/compare.sh       screenshot regression compare (magick, per-image tolerance) — library + CLI + selftest
lib/logcheck.sh      log event-signature compare (masked, ordered) — library + CLI + selftest
bin/run-example.sh   the runnable free-content example: 2 clients in one world, cross-client sync from logs
templates/           starting points: repro-template.sh, explore-client.sh
scenarios/           worked example fixtures + blessed references (free example-suite content)
docs/                the manuals (below)
```

## Documentation

- **[docs/WRITING-SCENARIOS.md](docs/WRITING-SCENARIOS.md)** — how to author a test: prepare a start
  state (position players, set spells/gear/skills, edit server save files), the fixture format,
  testing with **real game data** vs free content, avoiding the vanity camera, the action vocabulary,
  and the manual exploration loop.
- **[docs/VERIFICATION.md](docs/VERIFICATION.md)** — the three signal types and **when to use each**
  (log-gated vs static reference image vs dynamic pair), plus the exact ImageMagick metrics,
  thresholds, and freak-frame handling.
- **[docs/COOKBOOK.md](docs/COOKBOOK.md)** — the headless-action recipes: casting, scroll timing,
  camera turns, inventory drag-and-drop, item pickup, finding GUI click coordinates, catching a
  transient visual, and the combat-state confounds that make casts "flaky".
- **[docs/FEATURE-TESTS.md](docs/FEATURE-TESTS.md)** — worked patterns for feature guards: **PvP
  melee damage-sync**, **summon lifecycle + caster identity**, **magic-effect identity sync**, and
  **player→player effect sync** — each with its vehicle and its load-bearing assertions.

## License

MIT — see [LICENSE](LICENSE). Example scenarios use OpenMW's freely-licensed example-suite content.
Anything you author from a commercial game's data (e.g. Morrowind) is derived from that game's
content, is **not** MIT-covered, and should be kept out of a public repo (`scenarios/local/` is
gitignored for exactly this).
