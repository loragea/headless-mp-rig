# KB-16-ring-record-transient-visuals — Catch a transient visual: ring-record frames and keep the extreme one
Read when: a screenshot must catch a sub-second effect (a spell flash, a hit spark) on an observer's display.

**Confidence: VALIDATED**

Don't try to *time* the shot at a sub-second effect. The log line and the on-screen effect are only
loosely ordered: the actor's log line (for example its impact-sound report) and a ~0.3–0.5 s flash in
another client's view can fall either way round, so no single log-triggered grab is reliable. Both
simple forms fail: a fixed delay after the cast drifts out of phase when other timing changes, and a
grab on the log line catches near-idle frames.

Instead:
1. **Ring-record** the observer's frames from before the action until shortly after its log proof.
   `xwd` grabs (~0.15 s cadence) are about 3× faster than `import`; keep a ring of the last few
   seconds.
2. **Defer the CPU-heavy scoring** until the action's window has passed, so scoring doesn't steal
   time from the clients.
3. Keep the frame with the **largest RMSE against an idle baseline**: the effect at its observable
   peak, on whichever try landed.

A genuinely missing effect scores near the idle level everywhere and still fails.

**General pattern:** to catch a transient, don't time the shot; ring-record around the event and keep
the extreme frame.
