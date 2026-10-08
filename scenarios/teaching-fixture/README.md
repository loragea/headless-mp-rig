# teaching-fixture — the one fixture every teach-* scenario resumes

Not a scenario (it has no `scenario.conf`): the server state, the server scripts and the client
settings that the `teach-*` scenarios share. Each of them names it in its `scenario.conf`:

```sh
FIXTURE=../teaching-fixture                       # player/ cell/ world/ map/ recordstore/ custom/
OVERLAY=../teaching-fixture/coreScripts-overlay   # server scripts layered over a copy of your CoreScripts
SETTINGS=../teaching-fixture/settings.cfg         # seeded into every client profile
```

One fixture serving many tests is the normal shape: author a start state once, then let each
scenario set up what differs with server-pushed commands (`teach-setup-by-command`).

## What it holds

- `player/a.json`, `player/b.json` — two returning players (password `a` for both: b's save reuses
  a's login block) in exterior cell `0, -7`, 256 units apart, facing each other. They are the
  `scenarios/example` saves without the active water-breathing spell (below).
- `coreScripts-overlay/` — `example-suite-compat.lua` (stock CoreScripts crash on non-Morrowind
  content without it; `scenarios/example/README.md` explains) and `teaching-breath.lua`.
- `settings.cfg` — the `[Models]` remap the example-suite content needs to find a skeleton.

## Why water breathing comes from the server here

The example-suite world is entirely underwater: a player drowns about 25 s after login. The
`scenarios/example` saves carry a permanent active spell against that, but the spell's hit visual
does not exist in the free content, so every client logs `Error in frame: Static
'"VFX_DefaultHit"' not found` on every frame and the world update stops short: nobody can walk or
turn. That is harmless for a test that only logs in, fatal for one that moves. These saves carry no
active spell; `teaching-breath.lua` pushes `SetWaterBreathing 1` to each player at login instead
(server log `[teaching-breath] water breathing pushed to <p>`).

A client still drowns if it idles at its name box for about 45 s before login, so the scenarios
boot the second client only after the first player is in.
