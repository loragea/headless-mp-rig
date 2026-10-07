# KB-9-inventory-drop-two-clicks — Drop an inventory item into the world: two clicks, aim high for a feet-drop
Read when: a scenario drops an item from the inventory, or a dropped item lands somewhere unpredictable.

**Confidence: VALIDATED**

The engine's inventory drag-and-drop is **click-to-grab / click-to-release**, not a held drag:
1. Open the inventory (`rig_rmb`; the inventory action is the right mouse button).
2. **Click the item icon once.** It lifts onto the cursor (`ItemView` click →
   `InventoryWindow::dragItem` → `DragAndDrop::startDrag`). A `count == 1` item has no count dialog;
   a stack pops a count dialog first (shift-click takes the whole stack).
3. **Click a window-free part of the screen** (the 3D world or HUD). `HUD::onWorldClicked` drops it.

Two clean `xdotool click 1` calls, far easier to drive than a synthetic drag. The icon position is
GUI space; find it once with
[KB-13-find-gui-click-coordinates](KB-13-find-gui-click-coordinates.md).

**Where it lands.** `HUD::onWorldClicked` reads the cursor's viewport fraction and calls
`World::canPlaceObject(x, y)`:
- **True** (the camera ray hits a near-flat, upward-facing surface within **200 units**) →
  `placeObject` puts the item **at the ray's hit point**. Position-sensitive. Cursor: the normal arrow.
- **False** (the ray misses, or hits a wall, ceiling or actor, or is beyond 200 units) →
  `dropObjectOnGround` drops it **at the dropper's own feet**. Cursor: the `drop_ground` glyph
  (`HUD::onWorldMouseOver` swaps it live).

So for a **deterministic feet-drop with no pixel calibration, aim the second click high** (ceiling,
upper wall, the other actor), where placement is impossible. Don't aim at the open floor in front.
Put the *geometry* (dropper facing receiver) in the fixture, not in a calibrated click point.
