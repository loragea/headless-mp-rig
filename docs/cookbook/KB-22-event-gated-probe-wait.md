# KB-22-event-gated-probe-wait — Event-gated probe wait: poll a state until it holds instead of settling and probing once
Read when: an assertion reads a probe state that arrives after an unknown delay (a packet relay, an AI reaction, a death, a respawn, a spawn).

**Confidence: PARTIAL** — the verb is proven by its selftest against a fake probe; the caps to choose depend on the build and the box.

The pattern `settle N "…"` → `probe p kind` → `assert probe p kind cond` has two failure modes: N too
short under load (a false red), and N too long on an idle box (time wasted on every run). Both come
from guessing a delay that the engine does not promise.

`wait probe <p> <kind> <cond>… [cap]` asks the client probe for `<kind>` again and again (every
`RIG_PROBE_POLL` seconds, default 1) and passes on the first request where one line meets every
condition. The cap is the longest delay you accept, not the delay you expect: set it to two or three
times the slowest delay seen on a loaded box. A healthy run pays only the real delay.

```
console b "ModCurrentHealth -500"
wait probe a nearby actor=b dead=1 15     # the observer's copy dies; usually within 1-2 s
assert probe-count a nearby = 1 actor=b   # reads the request that passed: still exactly one copy
```

Rules that keep it honest:

- **Gate a positive state, then assert the rest.** The wait passes on presence (a line that meets
  the conditions). For absence (an actor gone, an item taken), wait on a positive state that comes
  with it, or on the log line of the event, then `probe` once and `assert probe-count … = 0`.
- **A baseline first.** Assert the opposite state before the trigger (`assert probe a nearby actor=b
  dead=0`); otherwise a pass can be a state that held all along.
- **What the line witnesses is unchanged.** Waiting does not turn a local value into a sync witness:
  read the witness table in [SCENARIO-FORMAT.md](../SCENARIO-FORMAT.md) §7 before choosing the client.
- **Each request is a bridge command**, so a long cap at a short poll fills `probe-<p>.log` and
  `bridge/`: keep the poll at 1 s or more.

Dead end: a `wait probe <p> <ERE>` on the probe log for a request line. Request lines appear only
when something requests them, so the ERE form waits for heartbeat and event lines (`seq=0`), not for
a state.
