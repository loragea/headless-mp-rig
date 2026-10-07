# KB-12-vanity-camera-idle-wiggler — The vanity camera after 30 s idle: run the idle wiggler for the whole run
Read when: a client looks like it booted in third person, the crosshair is gone, or an activate misses for no visible reason.

**Confidence: VALIDATED**

After **30 s** (`fVanityDelay`) without input the engine swings into the **vanity (idle) camera**: a
slowly orbiting third-person view that also **hides the crosshair** (`showCrosshair` in
`camera.cpp`). While it is active the centre-screen ray is wrong, so activate and pick-up silently
miss and screenshots are reframed.

This is the usual source of "camera mode / view angle is non-deterministic". It is not: the camera is
fully deterministic, the client just sat idle past 30 s. That is easy across boot plus a
choreography's sleeps, and a returning player can enter the world already expired, because typing at
the connect screen doesn't reset the idle timer. **Any input dismisses vanity**, and it re-arms after
another 30 s idle. A POV toggle (Tab) that seems "racy" is only dismissing vanity, which then re-arms
during the sleeps between presses.

**Fix:** `rig_start_idle_wiggler`, called once after the players are in-world, spawns a background
heartbeat that nudges the mouse 1 px and back on every booted display every `RIG_WIGGLE_INTERVAL`
(default 20 s, must stay below 30 s), firing immediately on start. The nudge direction alternates so
its warp-mode yaw cancels over pairs (net ~0 drift) and the cursor returns to screen centre; it
disturbs neither the gameplay aim nor a move-then-click GUI flow.

Any unexpected third-person or no-crosshair frame is vanity: wiggle, don't theorise. (See
[WRITING-SCENARIOS §5](../WRITING-SCENARIOS.md).)
