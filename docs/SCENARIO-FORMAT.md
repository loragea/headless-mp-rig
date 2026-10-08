# Scenario format — the directory, `scenario.conf` keys, the `steps.sh` verbs, exit codes, the run dir, the client probe and the server bridge
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
  setup/*.console        optional  console-command files for console-file, one command per line
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
| `PLAYERS` | login names in slot order, at most 3, each letters, digits or `_`: slot 1 → `RIG_DISPLAY`, 2 → `RIG_DISPLAY2`, 3 → `RIG_DISPLAY3` | required |
| `PASSWORDS` | passwords in the same order | each player's name |
| `TAGS` | free-form words; `bin/rig run --tag` selects on them, the rig never interprets them | — |
| `CONTENT` | a content profile from `rig.conf` (`RIG_CONTENT_<name>_*`) | required |
| `FIXTURE` | server state to resume: a dir holding the six state subdirs; `.` = this dir, `-` = blank state | `.` |
| `OVERLAY` | CoreScripts overlay dir, applied after the rig's own `overlay/` | none |
| `PROBE` | `1` = load the client probe (§7) in every client: the probe verbs, `probe-<p>.log`, the probe's boot milestone. Needs an OpenMW ≥ 0.48 client (Lua player scripts); on an older client (no `builtin.omwscripts` in the build's resources, or `RIG_RDF_BUILTIN=0`) the run prints a note, turns the probe off and the probe verbs `SKIP` | `0` |
| `PROBE_RANGE` | the probe's `nearby`/`items` radius in game units for this scenario; overrides `RIG_PROBE_RANGE` | `RIG_PROBE_RANGE` (2048) |
| `PROBE_PERIOD` | the probe's heartbeat period in seconds for this scenario; overrides `RIG_PROBE_PERIOD` | `RIG_PROBE_PERIOD` (5) |
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
is one row in `steps.tsv` carrying `steps.sh:<line>`. Things the shell will not tell you:

- Quote every argument that holds spaces or shell operators: `assert count server 'x' '>=' 2`. An
  unquoted `>=` is a redirection; `bin/rig lint` catches it.
- `steps.sh` runs under `set -u`: an unset variable (a misspelled `$P_NAME`) aborts it, and the run
  is `INFRA` "steps.sh aborted".
- The verbs `type` and `wait` replace the bash builtins of the same names inside `steps.sh` and
  `hooks.sh`.
- Verbs are not conditions: a `FAIL` row counts even inside an `if`.
- The fixture the players resume comes from a played session: [WRITING-SCENARIOS.md](WRITING-SCENARIOS.md) §1–2.
- The only server-log lines the rig itself guarantees on every fork are its bridge's:
  `[rig-bridge] loaded; data path …`, `[rig-bridge] commands from <dir>`,
  `[rig-bridge] player <p> in (pid N)`, `… out (pid N)`, and per setup command
  `[rig-bridge] <seq> <verb> <p>: <args>` then `[rig-bridge] <seq> done: …` or `… error: …`.
  Everything else is your build's and your scripts' logging.

`bin/rig lint <dir>` checks all of this without booting: the conf keys, every verb's arguments
(probe kinds and conditions included), an external command or redirection (an unquoted `<` in
`dist<400` too), a `--since` without an earlier `mark`, and shellcheck.

### 3.1 Log windows

The runner keeps a byte offset per log (server, each client and, with `PROBE=1`, each probe log
`probe-<p>`). **Before** a lifecycle, input, setup or custom verb acts, it records the current end of
every log: an **implicit mark**. A `wait` or `assert` after the verb therefore sees everything the
verb caused. `settle`, `wiggle`, `wait`, `assert`, `probe`, `shot`, `pair`, `signature`,
`checkpoint`, `note` and `artifact` never move it: `probe` is an observation, so an assert on a line
the previous verb caused still sees it after a `probe`. `boot` marks after
its clients start and before it waits for them; a server that `boot` starts is read from its first
line. `mark [name]` moves the mark explicitly and names the point; the name `start` is predefined
(offset 0 everywhere). A log that is shorter than its offset (a client restarted) is read from 0.

`wait server|client|probe` and `assert server|client` match **only past the last mark**; `--since <name>`
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
| `boot <p>…` | start the server (first call), one display and client per player; wait for each client's connection (cap `RIG_BOOT_CAP`), then its boot milestone (cap `RIG_WORLD_LOAD`), then `RIG_BOOT_SETTLE`. The milestone is the probe's `[rigprobe:ready]` line with `PROBE=1` (printed on the first frame the world simulation runs); otherwise `Sending ID_PLAYER_MAP` in the client log, or a rendered, settled frame on its display. A milestone that does not arrive is noted and the boot proceeds |
| `login <p> [returning\|fresh]` | type the name and password (`fresh` drives character generation); wait for the server's `[rig-bridge] player <p> in` (cap `RIG_LOGIN_CAP`) |
| `logout <p>` | stop the client; wait for `[rig-bridge] player <p> out` |
| `wiggle` | (re)start the idle wiggler on every booted display; `run` starts it after the first login unless `WIGGLE=0` |
| `settle <secs> "<reason>"` | sleep; the reason is required (a call without one fails) |

**A failed `boot` or `login` stops the scenario**: that row is `FAIL`, every later verb is
recorded `SKIP`, the RESULT is `INFRA`, exit 3. So does a server or client process that died: the
next verb records the `INFRA` row and names the log to read. `login <p> fresh` assumes the stock
TES3MP character-generation dialog sequence.

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
| `scroll <p> <quickkey> [<closekey>\|none] [until server <ERE> <cap> tries <n>]` | read a scroll bound to a quick-key: the quick-key, the close key (default `space`, which closes the read parchment; `none` during combat, where no parchment opens), then a cast; with `until`, retry until the server logs the ERE ([KB-2](cookbook/KB-2-scroll-quick-key-read-parchment.md)). A plain quick-key is `key <p> <n>` |
| `hidechat <p>` | press the chat toggle (`RIG_CHAT_KEY`, default `F6`) until the client logs `Chat hidden` ([KB-4](cookbook/KB-4-hide-chat-window.md)) |

### 3.4 Setup (server-pushed)

The server pushes setup to a logged-in player through the rig's bridge
(`overlay/scripts/custom/rig-bridge.lua`, §8). Each verb marks before it acts, waits for the bridge's
answer (cap `RIG_BRIDGE_CAP`, default 5 s) and records `OK` with the answer, or `FAIL` with the
bridge's reason (player not logged in, a Lua error). **No answer within the cap stops the scenario
as `INFRA`**, like a failed boot. Console commands go through the server on purpose: a client that
runs a console command the server did not queue is kicked by stock CoreScripts
([KB-21](cookbook/KB-21-server-pushed-console-command.md)).

| Verb | Effect |
|---|---|
| `console <p> "<mwscript>"` | the server runs `logicHandler.RunConsoleCommandOnPlayer(pid, cmd, false)`: p's client executes the command with p as the console's selected object. `OK` means the server sent it; assert its effect afterwards (`probe`, a client or server line). One line; no tabs |
| `console-file <p> setup/<f>.console` | every line of the file that is not blank or a `#` comment, in order, as one `console` each; one row. A refused line fails the row naming `<f>:<line>`; so does a command holding a tab (the bridge splits its command file on tabs), which `bin/rig lint` reports before a run |
| `console-object <p> "<cell>" <refnum>-<mpnum> "<mwscript>"` | `logicHandler.RunConsoleCommandOnObjects` on that object of the cell, run by p's client |
| `server <p> "<lua>"` | runs the Lua chunk inside the server, with `pid` (p's) and `player` (`Players[pid]`) bound; other names resolve to the server's globals, and new globals the chunk assigns stay in its own environment. A returned value is in the row's detail (`returned …`); an error fails the row |
| `server-file <p> setup/<f>.lua` | the file's text as one `server` chunk, for setup longer than one line. Every `$P_<NAME>` or `${P_<NAME>}` in it is replaced by that parameter's value before it is sent (a name that is not a `P_*` key of `scenario.conf` fails the row, and `bin/rig lint` reports it); nothing else is substituted. `bin/rig lint` also checks the substituted chunk's Lua syntax when `luac5.1`, `luajit` or `luac` is installed |
| `save <p>` | `Players[pid]:SaveToDrive()`: `player/<p>.json` is current for `assert json` |
| `save cell "<cell>"` | `LoadedCells[cell]:SaveToDrive()` (the cell must be loaded): `cell/<cell>.json` is current (a cell is otherwise written when it unloads) |
| `probe <p> <kind\|dump>` | ask p's client probe for a report (§7); waits until the probe's `[rigprobe:done] … seq=<seq>` line arrives (cap `RIG_PROBE_CAP`, default 10 s; a silent client is `FAIL`, and later asserts on that kind fail until a new request is answered). `OK` names the seq and the line count. `SKIP` when the probe is off or never became ready. Does not mark |

### 3.5 Waits

| Verb | Effect |
|---|---|
| `wait server <ERE> [cap]` | poll the server log past the last mark; default cap 10 s; a timeout is `FAIL` |
| `wait client <p> <ERE> [cap]` | the same on the client log |
| `wait probe <p> <ERE> [cap]` | poll `probe-<p>.log` past the last mark: request lines and the probe's own `seq=0` lines (heartbeat, quest and cell events). `SKIP` when the probe is off or never became ready |
| `wait probe <p> <kind> <cond>… [cap]` | request `<kind>` from p's probe every `RIG_PROBE_POLL` seconds (default 1) until one line of one request meets every condition (`PASS`, naming the line and the request count), or `cap` seconds (default 10) pass (`FAIL` quoting the last answered request). The form is chosen by its arguments: a probe kind followed by a `<field><op><value>` condition; anything else is the ERE form. Conditions are those of `assert probe`. Each request is an ordinary `probe` request, so a later `assert probe`/`assert probe-count` on that kind reads the one that passed. A request the client does not answer is asked again; a refused bridge command fails the row, a silent bridge is `INFRA`. `SKIP` as `assert probe`. Use it instead of `settle` + `probe` when a state arrives after an unknown delay ([KB-22](cookbook/KB-22-event-gated-probe-wait.md)) |
| `wait stable <p> <crop\|FULL> [cap] [eps] [delta]` | screen-stability wait ([KB-15](cookbook/KB-15-screen-stability-wait.md)); the baseline is the frame grabbed before the player's last input verb; a timeout is `OK` with detail `timeout` |

### 3.6 Assertions

Each records `PASS` or `FAIL` and never aborts the scenario.

| Verb | Source |
|---|---|
| `assert server <ERE> [cap]` | server log past the last mark, polled up to `cap` (default 10 s; server stdout is block-buffered) |
| `assert client <p> <ERE> [cap]` | the client log past the last mark, polled |
| `assert absent server <ERE>` / `assert absent client <p> <ERE>` | whole log: no line matches |
| `assert count server <fixed> <op> <n>` / `assert count client <p> <fixed> <op> <n>` | whole log, `grep -cF`; ops `= == != < <= > >=`, **quoted** (`'>='`: unquoted, `>` is a shell redirection) |
| `assert probe <p> <kind> <field><op><value>…` | the lines of the **last `probe` request** that answered `<kind>` for p (`probe p <kind>` or `probe p dump`), by its seq: `PASS` when one line meets every condition. Ops `=` `!=` (numbers compare as numbers, else as strings), `<` `<=` `>` `>=` (numbers), `~` (ERE). **Quote conditions holding `<` or `>`**: `'dist<400'`. A `FAIL` quotes the request's lines. No earlier request is a `FAIL`; so is a last request the client did not answer (its lines may still arrive and are never read as current): every assert on that kind fails until a new `probe` of it succeeds. Heartbeat and event lines (`seq=0`) are never read. A kind or field the client's probe lacks (its `caps=`) is `SKIP` naming the cap; so is a scenario with the probe off |
| `assert probe-delta <p> <kind> <field> <op> <n> [<cond>…] [<seqA> <seqB>]` | the field's value in request B minus request A (default: the last two requests that answered `<kind>`), compared with `<n>` (`= != < <= > >=`, numbers). In each request the first line that meets the optional conditions and holds a numeric `<field>` is used: `assert probe-delta b nearby dist '<' 0 actor=a` |
| `assert probe-count <p> <kind> <op> <n> [<cond>…]` | the number of `<kind>` lines of the last request answering `<kind>` that meet every condition, compared with `<n>` (`= != < <= > >=`). `= 0` asserts absence (`assert probe-count b nearby = 0 actor=c` after c left), `= 1` exactly one. Without conditions every line counts, including the `n=` header line of `topics`, `inv`, `faction` and `spells` |
| `assert json <relpath> '<python expression>'` | `python3 -I`; `d` is the parsed JSON document at `<work copy>/data/<relpath>`; truthy = `PASS` |
| `shot <p> <name> [crop]` | capture to `shots/<name>.png`. A blessed `reference-images/<name>.png` → compared (over tolerance: `REGRESSION`). None → `UNBLESSED` (exit 0); under `--strict-refs` → `NO-REFERENCE` (counts as a failure). A shot used only as a `pair` input is `OK` in the final `steps.tsv` (`run.log`, written live, still shows `UNBLESSED`). A cropped shot compares against a reference of the cropped size; a size mismatch is a `REGRESSION`. |
| `pair <name> <A> <B> [metric] [floor]` | shots A and B must differ: metric ≥ floor (default: the manifest row `<name>`, else `RMSE 0.02`) |
| `signature [name]` | the server log's event signature against `reference-logs/<name>.events` with `LOG_MARKERS` (default name: `NAME`); differs → `REGRESSION`; none → `UNBLESSED` / `NO-REFERENCE` |
| `checkpoint <name> [sp\|mp-only] [divergent]` | per logged-in player, into `checkpoints/<name>/`: a full-screen shot `<p>.png` and `<p>.probe`, a `probe <p> dump` (every kind, by its seq; a comment line instead when the probe is off). The mode words are recorded for a later single-player comparison and change nothing now |

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
  stubbed, `PATH` empty and an empty working directory; an external command, unknown verb, bad
  argument, redirection or unknown `--since` mark fails (exit 1). Writes nothing. `bin/rig lint`
  adds path checks and shellcheck.
- `--keep-up` — leave the server and clients running after the steps (one scenario only); implies
  `--keep-work`; refuses `--retry-failed`. Stop it with `bin/rig down`.
- A run refuses to start (exit 3) while a server is already running; `bin/rig down` stops it.
- `--keep-work` — keep the CoreScripts work copy (`RIG_KEEP_WORK=1`).

The other commands (`bin/rig help <command>` for each): `list`, `new`, `lint`, `explain` (the
failing steps of every attempt of a run with the file, byte window and line range to open),
`rerun-failed`, `stats` (counts, durations and a recent-versus-long-run judgment per scenario across
run sets, §5.1), `up` (a scenario's world left running for exploration), `down`, and `cmd` (one
server-bridge command to the world `up` left running: `bin/rig cmd probe a nearby`).

### 4.1 Exit codes and verdict

| Code | RESULT | Meaning |
|---|---|---|
| 0 | `PASS` / `PASS-RETRY` | all assertions passed; references within tolerance, or `UNBLESSED` without `--strict-refs` |
| 1 | `FAIL` | an assertion or wait failed, or `NO-REFERENCE` under `--strict-refs` |
| 2 | `REGRESSION` | assertions passed but a blessed frame or signature moved |
| 3 | `INFRA` | prerequisite, scenario-file, boot or login failure, the server bridge not answering, or the server or a client died |
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
  load.txt                   host load at the start and end of the run set (below)
  <scenario>/
    run.log                  every step stamped [t+Ns] steps.sh:<line>, plus the rig's notes
    steps.tsv                step  line  verb+args  status  t+s  offsets  detail
    RESULT                   the scenario's RESULT line
    env.txt                  RIG_* values, rig commit, CoreScripts commit, build id
    load.txt                 host load at the start and end of this attempt (below)
    server.log               server stdout
    server/                  config/openmw/tes3mp-server.cfg (run-scoped) and data/
    client-<p>.log           each client's stdout
    profiles/<p>/            a copy of each client's profile config at the end: openmw.cfg (the content
                             block it booted with), settings.cfg, MyGUI.log
    shots/<name>.png         captures + captures.tsv
    review/                  compare/logcheck output: diffs, candidate signatures
    checkpoints/<name>/      <p>.png and <p>.probe per checkpoint
    probe-<p>.log            the [rigprobe:*] lines of client-<p>.log (PROBE=1), one per line
    probe/                   the probe content the clients loaded (data= dir), with its probe_conf.lua
    bridge/                  the setup commands and the bridge's answers: cmd-<seq>.meta/.lua, done-<seq>, err-<seq>
    artifacts/               files copied by `artifact`
    corescripts/             the CoreScripts work copy (removed unless --keep-work)
    attempt-<k>/             an earlier attempt's tree (--retry-failed)
```

`steps.tsv` status is one of `PASS FAIL OK SKIP UNBLESSED NO-REFERENCE REGRESSION`. The offsets
column holds `log:start-end` for the window an assertion searched, and `log:offset` for each log
after a mark.

`load.txt` is `key=value` lines, written by the runner around every run set and every attempt (a
retried attempt's file moves into `attempt-<k>/` with the rest of it). It records load; it never
blocks or fails a run.

| Key | Value |
|---|---|
| `cores` | online CPUs (`nproc`) |
| `start_epoch`, `end_epoch` | Unix time |
| `start_loadavg`, `end_loadavg` | the 1-, 5- and 15-minute load averages (`/proc/loadavg`) |
| `start_busy`, `end_busy` | % of all cores busy over a `RIG_LOAD_SAMPLE`-second sample of `/proc/stat` (default 0.5; `0` turns the samples off and writes `-`) |
| `start_cpu` | the `/proc/stat` busy and total ticks at the start (input of `run_busy`) |
| `duration` | seconds from start to end |
| `run_busy` | % of all cores busy from start to end, the run's own server and clients included |

### 5.1 `bin/rig stats`

```
bin/rig stats [--runs N | --days D] [--scenario NAME]... [--window W] [--root DIR] [--json]
```

Reads every run set under `RIG_RUNS` (a directory with `RESULTS`; worlds from `bin/rig up` are left
out) and prints, per scenario: runs, attempts, first-attempt passes, `PASS-RETRY`, final `FAIL`,
`REGRESSION` and `INFRA`, the failed-attempt rate, the flake rate (runs that passed only on a retry),
mean and max attempt duration (`load.txt`, else the last `[t+Ns]` stamp of `run.log`), the last `W`
attempts as letters (`P` pass, `F` fail, `R` regression, `I` infra; default `W` = 10), and a judgment
of those attempts against all earlier ones:

| Judgment | Meaning |
|---|---|
| `ok` | no failure in the window |
| `unlucky (p=…)` | the window's failures are likely at the earlier failure rate |
| `suspicious (p=…)` | p < 0.05: re-run, and look at what changed |
| `likely regression (p=…)` | p < 0.01: the failure rate went up |
| `too few runs` | fewer than 10 earlier attempts to compare against |

`p` is the binomial probability of at least the window's number of failures in `W` attempts at the
earlier rate, estimated as (failures + 1) / (attempts + 2) so a clean history does not make one
failure impossible. A judgment row with failures also names the last failing step, the CPU busy at
its start and its directory. A final table gives the pass rate of all selected attempts by CPU busy
at attempt start (`start_busy`; `start_loadavg` per core for attempts recorded without a sample) in
the buckets <10 %, 10-30 %, 30-60 %, >=60 % and unknown. `--json` prints the same as one document,
with the busy buckets per scenario too. Exit 0, 1 when nothing is found, 64 usage.

## 6. Geometry contract

Every display is `RIG_SCREEN=1280x720x24` (`bin/rig doctor` fails otherwise unless
`RIG_GEOM_UNCHECKED=1`). The client window is 800×600, centred: its centre is screen `640,360`.
`click`/`mouse` take screen pixels; `look`/`turn` take offsets from `640,360`; a crop is
`WxH+X+Y` in screen pixels (ImageMagick geometry) or `FULL`. Find coordinates with
[KB-13](cookbook/KB-13-find-gui-click-coordinates.md).

## 7. The client probe

`PROBE=1` loads `probe/rig-probe.omwscripts` (a read-only Lua `PLAYER` script; OpenMW ≥ 0.48) as the
**last** content file of every client and lists it last in the server's `requiredDataFiles.json`, so
the plugin lists stay entry-for-entry equal. It is installed per run (`rig_use_probe` in
`lib/rig.sh`): the profile `openmw.cfg` and the work copy are run-scoped, nothing else is written.

**Lines.** Lua `print` goes to the client log at Info level; the runner copies the probe's lines into
`probe-<p>.log`, each starting at its tag:

```
[rigprobe:<kind>] p=<player> t=<simulation time> seq=<n> <key>=<value> ...
```

A value holding spaces is `"quoted"`. `seq=<n>` echoes the request (the bridge's command seq);
`seq=0` marks the probe's own lines. Every request ends with
`[rigprobe:done] … seq=<n> kind=<kind> lines=<count>` (plus `missing=<kinds>` the client lacks, or
`error=unknown-kind`). `p=` is the name the engine gives the player record: empty or the content's
default name before login, the login name after.

**When it prints.** `ready` once, on the first frame the world simulation runs: `probe=1 version=1
caps=<list> period=<s> range=<units>`. A request: the console command `lua rigprobe <kind|dump> <seq>`,
which only the server sends (the `probe` verb). Events with `seq=0`: `quest` when a quest index
changes (the engine's `onQuestUpdate`, also when the server loads the journal at login), `cell` when
the player's cell changes, `inv` when the inventory changes (checked every 2 s). A heartbeat with
`seq=0`: `cell` and `stats` every `PROBE_PERIOD` (else `RIG_PROBE_PERIOD`) seconds (default 5).

| kind | one line per … | fields |
|---|---|---|
| `cell` | request | `cell` (name) `id` `x y z` (rounded) `exterior` (0/1) `gridx gridy` (exteriors) |
| `stats` | request | `hp hpbase mp mpbase fat fatbase` (current and base, rounded) `level` `stance` (`nothing`/`weapon`/`spell`) `dead` (0/1) `deathdone` (0/1: the death animation finished) |
| `quest` | started quest | `id stage finished` (0/1) |
| `topics` | known topic, after one `n=<count>` line | `topic` |
| `inv` | record id, after one `n=<ids> more=0/1` line (at most 40) | `item=<id>:<count>` `id` `count` |
| `nearby` | actor, door or container within the range (`PROBE_RANGE`, else `RIG_PROBE_RANGE`, default 2048), nearest first (at most 80) | actors: `actor` (name; a remote player is an NPC named after its login) `rec` `dist` `kind` (`npc`/`creature`/`player`) `x y z` (absolute position, rounded) `stance` `anim` (lower-body animation group, `none` when idle without one) `animup` (torso group) `hp` `dead` (0/1) `weapon` (record id of the right-hand equipment, `none`); doors and containers: `obj` (record id) `name` `kind` (`door`/`container`) `dist` `lock` (level) `locked` (0/1) |
| `items` | item lying in the active cells within the range, nearest first (at most 80) | `obj` (record id) `name` `count` `dist` `x y z` |
| `effects` | active spell on the player, then one per applied effect of it, then one per summed active effect (at most 80 lines) | spell: `spell` (id) `name` `caster` (record id) `castername`; its effects: `spell` `effect` (id) `attr`/`skill` (the affected attribute or skill, when the effect has one) `mag` (this frame) `left` (seconds; absent for constant effects); summed: `net=1` `effect` `attr`/`skill` `mag` |
| `faction` | faction the player is in, after one `n=<count>` line | `faction` (id) `rank` |
| `spells` | spell the player knows, after one `n=<count>` line (at most 80) | `spell` (id) `name` |
| `time` | request | `gametime` (seconds) `hour` `day` `scale` |
| `weather` | request | `weather` `next` (record ids; `none` in an interior) `transition` |

`dump` answers every kind in this order. **Caps** are the bindings this engine has: `cell stats
stance quest topics inv nearby items effects faction spells anim lock dead deathdone equip time
weather`; a kind, or a field whose cap is missing (`anim`/`animup` → `anim`, `lock`/`locked` →
`lock`, `stance`, `dead`, `deathdone`, `weapon` → `equip`), is `SKIP` in `assert probe`. `RIG_PROBE_CAPS_OFF`
(comma list) makes the probe report caps as missing: a way to test that path.

**Conditions.** All conditions of one `assert probe` must hold on **one** line. For a kind with many
lines, name the row with its key field (`actor=`, `rec=`, `obj=`, `id=`, `item=`, `spell=`,
`effect=`, `faction=`) next to the field you test. A value holding spaces is compared without its
quotes: `'rec=some npc'`; `~` is an ERE on the unquoted value. `anim` values are the engine's
animation group names (`idle`, `idle2`–`idle9`, `walkforward`, `runforward`, `weapononehand`, …).
`nearby` and `items` see only the active cells (an interior: that cell; an exterior: the 3×3 grid
around the player), and only within the range.

**What each field witnesses.** A probe line reports this client's engine. It is evidence of
synchronisation only when the client could have got the value from the network alone. On a client
that did **not** act:

| kind.field | set on the observing client by | witness of sync? |
|---|---|---|
| `nearby` row exists (`actor=`, `rec=`), `kind` | creation of the remote player or remote-controlled actor from packets | yes |
| `nearby.x y z` | position packets | yes |
| `nearby.dist` | position packets, **relative to the observer**: it also changes when the observer moves | yes, with care; prefer `x y z` for motion |
| `nearby.stance` | animation-flag packets (AI does not run on a remote-controlled actor) | yes |
| `nearby.anim`, `animup` | **this client's** animation controller: idle and movement groups play whenever a skeleton is loaded, and the authority's AI picks `idle2`–`idle9` at random | only for a group that neither idling, movement nor combat produce; `anim~idle` proves a rendered skeleton, not sync |
| `nearby.hp` | stats packets on a third client; on the **attacker's** client also its local hit on the copy | yes on a third client; never assert damage from the attacker's own `nearby hp` |
| `nearby.dead`, `weapon` | death and equipment packets | yes |
| `nearby.lock`, `locked` | lock packets, unless an MWScript on the door locks it (every client runs it) | yes on a scriptless door |
| `items` row | object place/delete packets | yes |
| `stats.hp mp fat` (own) | incoming damage and spell packets **and** local regeneration (fatigue regenerates: give a `fat` delta a margin) | yes for a received hit, with a margin |
| `stats.dead`, `deathdone` (own) | the player's own death | local |
| `cell.*` (own) | the player's own movement | only after a server-pushed teleport |
| `quest`, `topics` (own) | shared-journal packets when another player acts (if the server shares the journal) | yes on the player who did not act |
| `inv` (own) | the player's own actions; a pickup also waits for the server's echo | medium |
| `effects`, `spells`, `faction` (own) | spell and faction packets when the server or another player acts | yes when this player did not cast or join |
| `time.*` | **this client's clock**, advancing at the same rate everywhere: equal times prove nothing | only after a server-pushed time change |
| `weather.*` | weather packets from the region's authority, but the local weather manager also runs | only a weather forced that the region would not pick |

**Joining by hand.** The probe is listed in the server's `requiredDataFiles.json` for the run, so the
server refuses any client without it: a human joining a world from `bin/rig up` needs
`rig-probe.omwscripts` last in their own content list too (the run's `probe/` directory holds it).

## 8. The server bridge

`overlay/scripts/custom/rig-bridge.lua` is layered into every CoreScripts work copy. With
`RIG_BRIDGE_DIR` set in the server's environment (the runner sets it to `<run>/bridge`), a 250 ms
timer executes command files in seq order, 1, 2, 3 …:

| File | Content |
|---|---|
| `cmd-<seq>.meta` | one line, tab-separated: `<verb> <player> <arg>…`; written to a temp name and renamed |
| `cmd-<seq>.lua` | the chunk of a `lua` command, written before its `.meta` |
| `done-<seq>` | one line: what ran (`sent to pid 0`, `returned 3`, `saved player a`) |
| `err-<seq>` | one line: why not (`player zz is not logged in`, `runtime: …`) |

Verbs: `console <p> <cmd>`, `object <p> <cell> <refnum-mpnum> <cmd>`, `probe <p> <kind>` (sends
`lua rigprobe <kind> <seq>`), `lua <p>`, `save <p>`, `savecell - <cell>`. The bridge adds one global
(`RigBridgePoll`, the timer callback TES3MP calls by name).

**Prerequisites** (checked by `bin/rig doctor`): the CoreScripts tree has `scripts/customScripts.lua`
and `serverCore.lua` requires it (the rig appends `require("custom/rig-bridge")` to it); the
TES3MP 0.7+ CoreScripts API: `customEventHooks`, `logicHandler` (`RunConsoleCommandOnPlayer`,
`RunConsoleCommandOnObjects`), `Players`, `LoadedCells`, `Player:SaveToDrive`, `Cell:SaveToDrive`;
the Lua `io` and `os` libraries (present in stock TES3MP). Without the event hooks or `logicHandler`
the bridge logs `[rig-bridge] off: …` and stays off, so the server still starts; every login then
fails as `INFRA` naming that line. A verb whose function is missing answers `err-<seq>` naming it.

