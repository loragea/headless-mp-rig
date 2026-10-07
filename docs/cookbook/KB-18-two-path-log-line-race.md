# KB-18-two-path-log-line-race — A log line emitted on only one of two engine paths: assert the state change instead
Read when: an assert on a relay or log line flakes while the action it reports always succeeds.

**Confidence: VALIDATED**

Worked case, TES3MP-lineage item pickup: "the receiver played the item-pickup sound" flaked in about
a quarter of runs while the pickup itself passed every time. Whether the pickup's `ID_OBJECT_SOUND`
relay fires depends on **which client-side take path** the server's ObjectActivate echo lands in.
The take executed through `ActionTake` (`action.cpp`) relays the sound; the GUI `pickUpObject` path
doesn't. That is an engine-internal race the script cannot reach.

So:
- **Remove the assert; don't loosen it.** A retry or a tolerance only hides a race you can't
  control.
- **Gate the action on its deterministic chain**: for a pickup, `Accepted ObjectActivate` plus
  `Accepted ObjectDelete` on the server.
- **Cover the relay layer through a vehicle that always takes the emitting path**, for example the
  hit sound of a Target-range spell projectile, which the server logs as `played sound <hit sound>`.

General rule: when a signal has two engine paths and only one emits your log line, don't assert the
line. Assert the state change, and test the layer through a vehicle that deterministically takes the
emitting path.
