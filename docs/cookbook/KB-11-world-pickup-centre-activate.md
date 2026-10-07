# KB-11-world-pickup-centre-activate — Pick a world item up: face it and activate, with the aim set in the fixture
Read when: a scenario picks an item up from the world, or an activate silently misses.

**Confidence: VALIDATED**

`space` (activate) picks up the *faced* object: a ray from the camera through screen centre,
range-limited to `iMaxActivateDist` (192 units). The receiver just has to look at the item, in
normal first-person view, within range.

Put that aim in the **fixture**, not in the script. A downward pitch θ puts the first-person
crosshair on the floor at horizontal distance ≈ `eye-height / tan θ`, so author the receiver's pitch
to match the item's distance.

The one thing that breaks this is the vanity camera
([KB-12-vanity-camera-idle-wiggler](KB-12-vanity-camera-idle-wiggler.md)). Rule that out first; the
activate itself is trivial.
