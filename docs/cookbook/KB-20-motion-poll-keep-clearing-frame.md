# KB-20-motion-poll-keep-clearing-frame — Motion-poll a differential pair: keep the frame that cleared the floor as t1
Read when: the second frame of a motion pair must land inside a short window, or a motion pair passes on a poll but fails on a re-grab.

**Confidence: VALIDATED**

A differential pair ([KB-8-differential-motion-screenshots](KB-8-differential-motion-screenshots.md))
taken with a fixed sleep wastes time inside tight windows and can miss the motion. Poll instead:

1. **Take t0 before the trigger**, while the subject is idle. Idle-vs-moving gives a larger, tighter
   diff than moving-vs-moving.
2. After the trigger, **poll the witness's view**: grab, compute RMSE against t0 (~0.5 s per
   iteration with `import`), until the diff clears the pair's floor × a margin.
3. **Keep the clearing frame as t1.** Don't re-grab: motion is non-monotonic (±0.01 frame to frame),
   and a fresh grab 0.5 s later can dip under the floor. A frozen subject never produces a clearing
   frame, so keeping it masks nothing.
4. **Cap the poll** (a couple of seconds from the trigger event). On expiry take t1 blind and carry
   on when a harder assertion follows (a capped poll means the subject barely moved).

When the actor is a different client on its own display, keeping the frame and the actor's next
input can run back-to-back.
