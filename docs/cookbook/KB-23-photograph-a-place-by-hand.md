# KB-23-photograph-a-place-by-hand — Photograph a running world by hand: a camera player moved by server-pushed console commands
Read when: a test reports a position, a path or an anomaly that nobody can picture from the numbers; or before blessing a reference frame of a place nobody has looked at.

**Confidence: VALIDATED** (OpenMW 0.51-based TES3MP client and server, stock CoreScripts, software GL)

**What it is for.** A test asserts on positions or a path and a human cannot judge whether the
numbers are right; an anomaly is known but not understood; a reference frame is about to be blessed
of a place nobody has seen. Put a camera in the running world and look.

**What it is not.** Not a verification signal. Nothing from it enters a scenario until it is turned
into a `shot` or a probe assertion. The pictures answer "what is there"; they prove nothing on the
next run.

## The loop

1. **Bring the world up.** `bin/rig up <scenario dir>` boots the server and clients and logs them in
   without running the steps. It prints each player's display. Pick one player as the camera
   (below: `c` on display `:99`). The scenario needs `PROBE=1` for step 5's probes.
2. **Light it.** The world loads at the fixture's clock, often night. Set noon and stop the clock
   from the server, then confirm on the client:

   ```sh
   bin/rig cmd lua c "WorldInstance.data.time.hour = 12; WorldInstance.data.time.dayTimeScale = 0; WorldInstance.data.time.nightTimeScale = 0; WorldInstance:UpdateFrametimeMultiplier(); WorldInstance:LoadTime(pid, true)"
   bin/rig cmd probe c time      # hour=12 scale=0
   ```

   This is the chunk of `scenarios/teach-reference-frame/setup/pin-hour.lua`; in a scenario it is
   `server-file <p> setup/pin-hour.lua`. `LoadTime(pid, true)` sends the time to every player.
3. **Move the camera** with server-pushed console commands (`bin/rig cmd console c "…"`; a typed
   command gets the client kicked, [KB-21](KB-21-server-pushed-console-command.md)):
   - position: `SetPos X <x>`, `SetPos Y <y>`, `SetPos Z <z>` (one command each);
   - yaw: `SetAngle Z <deg>`: 0 faces +Y (north), 90 faces +X (east);
   - pitch: `SetAngle X <deg>`: 89 looks straight down;
   - above the ground: `ToggleCollision` first, or the player falls back to the ground before the
     shot. Send it again to turn collision back on.

   Stay in first person: the third-person camera puts the player's body in the picture.
4. **Shoot.** Wait a few seconds for software GL to draw the new view, then
   `DISPLAY=:99 import -window root shot.png`. Read the first shot: a menu, a dialogue box or the
   vanity camera ([KB-12](KB-12-vanity-camera-idle-wiggler.md)) must be dismissed before the rest
   mean anything.
5. **Record where everything was.** `bin/rig cmd probe c cell` gives the camera's own position;
   `bin/rig cmd probe c nearby` gives each actor's. Probe right before each shot: an actor with an
   idle or wander package moves between shots even when nothing was triggered.
6. **Stop it.** `bin/rig down`.

## The standard set for a path or a walk

1. Eye level, behind the start, looking along the path.
2. Beyond the end, looking back at the start.
3. Straight down from 900–1200 units above the midpoint (collision off, pitch 89).
4. From one side, far enough out that the whole segment is in frame.
5. Trigger the action, for example a travel order on one object:
   `bin/rig cmd object c "<cell>" <refnum>-<mpnum> "AiTravel <x> <y> <z>"`.
6. Retake the start view and the overhead view, and probe `nearby` again.

Name each shot after its view and keep the probe lines beside it; the pair is the record.

## What the probe can and cannot tell

`nearby` lists actors (position, animation, stance), doors and containers within the probe range
(SCENARIO-FORMAT.md §7). It does not list statics, terrain or any collision geometry. A wall, a fence
or a slope that blocks a path shows only in the pictures.

## Dead ends

- *A side shot at eye level plus a few hundred units, collision on*: the next `cell` probe shows the
  camera back on the ground; the view is not the one you asked for.
- *Judging motion from `dist`*: it is relative to the camera, which you just moved. Compare `x y z`.
