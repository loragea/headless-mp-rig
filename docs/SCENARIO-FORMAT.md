# Scenario format — the directory, `scenario.conf` keys, the `steps.sh` verbs, exit codes and the run dir
Read when: writing or reading a scenario that `bin/rig run` executes, or a tool that consumes its results.

A scenario is a directory. `bin/rig run <dir>` boots a dedicated server and one client per player,
executes `steps.sh` verb by verb, and writes one verdict. This file is the contract; the code in
`lib/scenario.sh` implements it.

## 1. Directory

```
<scenario>/
  scenario.conf          REQUIRED  metadata: the fixed keys below plus P_* parameters
  steps.sh               REQUIRED  the choreography: verbs only (§3)
  hooks.sh               optional  bash; each function verb_<name>() becomes a verb <name>
  README.md              optional  what it proves and which regression it guards
  setup/*.console        optional  console-command files, one command per line
  overlay/               optional  CoreScripts overlay tree (OVERLAY=); <file>.append lines are appended
  player/ cell/ world/ map/ recordstore/ custom/   optional  the fixture: server state the run resumes
  reference-images/      optional  blessed frames + manifest.tsv (docs/VERIFICATION.md)
  reference-logs/        optional  blessed <name>.events signatures (docs/VERIFICATION.md)
```

## 2. `scenario.conf`

Shell `KEY=value` lines. Discovery parses the file without running it; `run` sources it. Any key
outside this list fails, except `P_<NAME>` (upper case, digits, `_`).

| Key | Meaning | Default |
|---|---|---|
| `NAME` | scenario name; names the run subdirectory and the `RESULT` line | directory name |
| `PURPOSE` | one sentence: what the scenario proves | — |
| `PLAYERS` | login names in slot order: slot 1 → `RIG_DISPLAY`, 2 → `RIG_DISPLAY2`, 3 → `RIG_DISPLAY3` | required |
| `PASSWORDS` | passwords in the same order | each player's name |
| `TAGS` | free-form words; `bin/rig run --tag` selects on them, the rig never interprets them | — |
| `CONTENT` | a content profile from `rig.conf` (`RIG_CONTENT_<name>_*`) | required |
| `FIXTURE` | server state to resume: a dir holding the six state subdirs; `.` = this dir, `-` = blank state | `.` |
| `OVERLAY` | CoreScripts overlay dir, applied after the rig's own `overlay/` | none |
| `PROBE` | `1` = load the client probe (not available yet; ignored with a note) | `0` |
| `SETTINGS` | a client `settings.cfg` seeded into every client profile | none |
| `LOG_MARKERS` | ERE vocabulary for `signature`; may reference `$RIG_TRIPWIRES` | `lib/logcheck.sh` default |
| `COST` | approximate minutes on software GL | — |
| `WIGGLE` | `0` = do not start the idle wiggler after the first login | `1` |
| `P_<NAME>` | a scenario parameter, exported to `steps.sh` as `$P_<NAME>` | — |

Relative paths (`FIXTURE`, `OVERLAY`, `SETTINGS`) are relative to the scenario directory.
`RIG_TRIPWIRES` is a rig constant: the server-log error lines that must never appear
(`script error|Server crash|bad argument|luabridge|Error in frame`).

## 3. `steps.sh` verbs

`steps.sh` is bash restricted to verbs, `local`, variables and `if`/`for`/`case`: no pipes,
subshells, redirections or external commands. Players are **names** from `PLAYERS`. Every verb call
is one row in `steps.tsv` carrying `steps.sh:<line>`.

### 3.1 Log windows

The runner keeps a byte offset per log (server, each client). **Before** a lifecycle, input, setup or
custom verb acts, it records the current end of every log: an **implicit mark**. A `wait` or `assert`
after the verb therefore sees everything the verb caused. `settle`, `wiggle`, `wait`, `assert`,
`shot`, `pair`, `signature`, `checkpoint`, `note` and `artifact` never move it. `boot` marks after
its clients start and before it waits for them; a server that `boot` starts is read from its first
line. `mark [name]` moves the mark explicitly and names the point; the name `start` is predefined
(offset 0 everywhere). A log that is shorter than its offset (a client restarted) is read from 0.

`wait server|client` and `assert server|client` match **only past the last mark**; `--since <name>`
(anywhere in the arguments) widens the window to a named mark, and a `--since` without a name fails.
`assert count` and `assert absent` read the whole log. Matching is `grep -E`, case-sensitive.

Put each assert right after the verb that causes its line; `mark <name>` before a trigger whose
effect you assert later, after other verbs have moved the mark:

```
login a
assert server 'Authority of cell .* is now a'     # logged during login a: inside the window
mark before-door
chat a "/opendoor"
key b space                                        # moves the mark past the door line
assert server --since before-door 'door opened'    # widened back to the named mark
```

`--since start` reopens the whole log: an earlier occurrence of the line then passes the assert.
Use it only for lines that can occur once per run.

### 3.2 Lifecycle

| Verb | Effect |
|---|---|
| `boot <p>…` | start the server (first call), one display and client per player; wait for each client's connection (cap `RIG_BOOT_CAP`), then its boot milestone: `Sending ID_PLAYER_MAP` in the client log, or a rendered, settled frame on its display (cap `RIG_WORLD_LOAD`), then `RIG_BOOT_SETTLE` |
| `login <p> [returning\|fresh]` | type the name and password (`fresh` drives character generation); wait for the server's `[rig-bridge] player <p> in` (cap `RIG_LOGIN_CAP`) |
| `logout <p>` | stop the client; wait for `[rig-bridge] player <p> out` |
| `wiggle` | (re)start the idle wiggler on every booted display; `run` starts it after the first login unless `WIGGLE=0` |
| `settle <secs> "<reason>"` | sleep; the reason is required by lint |

**A failed `boot` or `login` stops the scenario**: that row is `FAIL`, every later verb is
recorded `SKIP`, the RESULT is `INFRA`, exit 3.

### 3.3 Input

| Verb | Effect |
|---|---|
| `key <p> <keys>…` | `xdotool key` keysyms |
| `hold <p> <key\|mouse1\|mouse3> <secs>` | press, hold, release (a melee swing is `hold p mouse1 0.7`) |
| `type <p> <text>` | type text |
| `mouse <p> <x> <y>` | move the pointer, no click |
| `click <p> <x> <y>` | move and left-click |
| `rmb <p>` | right-click (the inventory/menu toggle) |
| `look <p> <dx> <dy>` | mouse-look: one pointer offset from the window centre |
| `turn <p> <dx> <steps>` | repeated horizontal offsets: a yaw turn |
| `chat <p> "/cmd"` | open chat, type, submit |
| `cast <p>` | held left click ([KB-1](cookbook/KB-1-synthetic-left-click-cast.md)) |
| `scroll <p> <quickkey> [until server <ERE> <cap> tries <n>]` | quick-key, `space` (close the parchment), cast; with `until`, retry until the server logs the ERE ([KB-2](cookbook/KB-2-scroll-quick-key-read-parchment.md)) |
| `hidechat <p>` | press the chat toggle (`RIG_CHAT_KEY`, default `F6`) until the client logs `Chat hidden` ([KB-4](cookbook/KB-4-hide-chat-window.md)) |

### 3.4 Setup (server-pushed)

`console <p> "<mwscript>"`, `console-file <p> setup/<f>.console`,
`console-object <p> "<cell>" <refnum-mpnum> "<cmd>"`, `server <p> "<lua>"`,
`save <p>` / `save cell "<cell>"`, `probe <p> <kind|dump>`.
These need the server bridge, which does not execute commands yet: each records `SKIP` with
detail `bridge: R3` and still marks.

### 3.5 Waits

| Verb | Effect |
|---|---|
| `wait server <ERE> [cap]` | poll the server log past the last mark; default cap 10 s; a timeout is `FAIL` |
| `wait client <p> <ERE> [cap]` | the same on the client log |
| `wait probe <p> <ERE> [cap]` | probe not available yet: `SKIP` |
| `wait stable <p> <crop\|FULL> [cap] [eps] [delta]` | screen-stability wait ([KB-15](cookbook/KB-15-screen-stability-wait.md)); the baseline is the frame grabbed before the player's last input verb; a timeout is `OK` with detail `timeout` |

### 3.6 Assertions

Each records `PASS` or `FAIL` and never aborts the scenario.

| Verb | Source |
|---|---|
| `assert server <ERE> [cap]` | server log past the last mark, polled up to `cap` (default 10 s; server stdout is block-buffered) |
| `assert client <p> <ERE> [cap]` | the client log past the last mark, polled |
| `assert absent server <ERE>` / `assert absent client <p> <ERE>` | whole log: no line matches |
| `assert count server <fixed> <op> <n>` | whole server log, `grep -cF`; ops `= == != < <= > >=` |
| `assert probe …`, `assert probe-delta …` | probe not available yet: `SKIP` |
| `assert json <relpath> '<python expression>'` | `python3 -I`; `d` is the parsed JSON document at `<work copy>/data/<relpath>`; truthy = `PASS` |
| `shot <p> <name> [crop]` | capture to `shots/<name>.png`. A blessed `reference-images/<name>.png` → compared (over tolerance: `REGRESSION`). None → `UNBLESSED` (exit 0); under `--strict-refs` → `NO-REFERENCE` (counts as a failure). A shot used only as a `pair` input is `OK`. |
| `pair <name> <A> <B> [metric] [floor]` | shots A and B must differ: metric ≥ floor (default: the manifest row `<name>`, else `RMSE 0.02`) |
| `signature [name]` | the server log's event signature against `reference-logs/<name>.events` with `LOG_MARKERS` (default name: `NAME`); differs → `REGRESSION`; none → `UNBLESSED` / `NO-REFERENCE` |
| `checkpoint <name> [sp\|mp-only] [divergent]` | a full-screen shot per logged-in player into `checkpoints/<name>/`, plus a placeholder `<p>.probe` until the probe exists |

### 3.7 Misc

`mark [name]`, `note "<text>"` (into `run.log`), `artifact <file> [name]` (copy a file, relative to
the work copy's `data/`, into `artifacts/`).

### 3.8 Custom verbs

A function `verb_<name>` in `hooks.sh` is callable as `<name> <args>` (it must not shadow a built-in
verb). Return 0 records `OK`, non-zero records `FAIL`; the call marks like an input verb. Hooks see `RIG_RUN_DIR` (this attempt's
scenario dir), `RIG_SET_DIR` (the run-set dir) and `SC_DIR` (the scenario source dir).

## 4. `bin/rig run`

```
bin/rig run <dir>... | --tag T | --all  [--out DIR] [--capture] [--strict-refs] [--retry-failed N]
                                         [--dry-run] [--keep-up] [--keep-work]
```

- `<dir>` holding `scenario.conf` is one scenario; any other dir is searched for scenarios.
  `--tag`/`--all` without dirs search `RIG_SCENARIOS` (default `<rig>/scenarios`). Several `--tag`
  must all match. Scenarios run serially, one server at a time.
- `--out DIR` — the run-set dir (default `$RIG_RUNS/<YYYYmmdd-HHMMSS>-<name|set>`).
- `--capture` — capture candidates, compare nothing: `shot`/`signature` record `OK`.
- `--strict-refs` — a missing reference is `NO-REFERENCE`, a failure.
- `--retry-failed N` — re-run a scenario whose RESULT is `FAIL`, `REGRESSION` or `INFRA`, up to
  N times; earlier attempts move to `attempt-<k>/`; a pass on a retry is `PASS-RETRY`.
- `--dry-run` — no boot: `bash -n`, the conf key check, then `steps.sh` sourced with every verb
  stubbed and `PATH` empty; an external command or unknown verb fails. Writes nothing.
- `--keep-up` — leave the server and clients running after the steps (one scenario only); implies
  `--keep-work`. Tear down with `pkill -x <server-bin>; pkill -x <client-bin>; pkill -x Xvfb`.
- `--keep-work` — keep the CoreScripts work copy (`RIG_KEEP_WORK=1`).

### 4.1 Exit codes and verdict

| Code | RESULT | Meaning |
|---|---|---|
| 0 | `PASS` / `PASS-RETRY` | all assertions passed; references within tolerance, or `UNBLESSED` without `--strict-refs` |
| 1 | `FAIL` | an assertion or wait failed, or `NO-REFERENCE` under `--strict-refs` |
| 2 | `REGRESSION` | assertions passed but a blessed frame or signature moved |
| 3 | `INFRA` | prerequisite, scenario-file, boot or login failure, or the server died |
| 4 | `SKIP` | the content profile is not present on this box (the `rig.conf` key is named) |
| 64 | — | usage error |

A run-set exits with the most severe code in the order **3 > 1 > 2 > 4 > 0**; 4 only when every
selected scenario skipped. Each scenario writes one line, and `RESULTS` holds one per scenario:

```
RESULT <status> <code> <scenario> <fails> <regressions> <attempts>
```

## 5. Run directory

```
$RIG_RUNS/<YYYYmmdd-HHMMSS>-<name|set>/     (or --out)
  RESULTS                    one RESULT line per scenario
  <scenario>/
    run.log                  every step stamped [t+Ns] steps.sh:<line>, plus the rig's notes
    steps.tsv                step  line  verb+args  status  t+s  offsets  detail
    RESULT                   the scenario's RESULT line
    env.txt                  RIG_* values, rig commit, CoreScripts commit, build id
    server.log               server stdout
    server/                  config/openmw/tes3mp-server.cfg (run-scoped) and data/
    client-<p>.log           each client's stdout
    shots/<name>.png         captures + captures.tsv
    review/                  compare/logcheck output: diffs, candidate signatures
    checkpoints/<name>/      <p>.png and <p>.probe per checkpoint
    artifacts/               files copied by `artifact`
    corescripts/             the CoreScripts work copy (removed unless --keep-work)
    attempt-<k>/             an earlier attempt's tree (--retry-failed)
```

`steps.tsv` status is one of `PASS FAIL OK SKIP UNBLESSED NO-REFERENCE REGRESSION`. The offsets
column holds `log:start-end` for the window an assertion searched, and `log:offset` for each log
after a mark.

## 6. Geometry contract

Every display is `RIG_SCREEN=1280x720x24` (`bin/rig doctor` fails otherwise unless
`RIG_GEOM_UNCHECKED=1`). The client window is 800×600, centred: its centre is screen `640,360`.
`click`/`mouse` take screen pixels; `look`/`turn` take offsets from `640,360`; a crop is
`WxH+X+Y` in screen pixels (ImageMagick geometry) or `FULL`. Find coordinates with
[KB-13](cookbook/KB-13-find-gui-click-coordinates.md).
