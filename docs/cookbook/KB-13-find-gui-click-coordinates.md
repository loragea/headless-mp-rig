# KB-13-find-gui-click-coordinates — Find GUI click coordinates headlessly: a labelled grid overlay, or grab-and-identify
Read when: a scenario must click a GUI element (an item icon, a button, a menu row) whose screen position you don't know.

**Confidence: VALIDATED**

There is no accessibility tree to query, and synthetic mouse moves don't reliably fire MyGUI tooltips,
so you can't hover and read a label. Two techniques give exact click points:

1. **Labelled coordinate grid.** Screenshot the display, crop the region, upscale it, and draw
   gridlines labelled with the *full-resolution screen coordinates*; then read a widget's centre
   straight off the picture (`screenX = cropX0 + zoomX / scale`). Pass the draw commands **inline**:
   some ImageMagick policies block `-draw @file`.
   ```sh
   # W,H = crop size; X0,Y0 = crop origin; S = integer zoom
   import -window root /tmp/s.png
   magick /tmp/s.png -crop ${W}x${H}+${X0}+${Y0} +repage -filter point -resize $((S*100))% /tmp/b.png
   D="fill none stroke red stroke-width 1 "
   for sx in $(seq $X0 14 $((X0+W))); do zx=$(((sx-X0)*S)); D+="line $zx,0 $zx,$((H*S)) "; done
   D+="stroke none fill yellow font-size 13 "
   for sx in $(seq $X0 28 $((X0+W))); do zx=$(((sx-X0)*S)); D+="text $((zx+1)),14 '$sx' "; done
   magick /tmp/b.png -draw "$D" /tmp/grid.png     # add the same loop for horizontal (Y) lines
   ```
   Works for any UI target: item icons, buttons, menu rows, map pins, crop rectangles.
2. **Grab-and-identify** (when icons are ambiguous). Click a candidate to lift it onto the cursor
   ([KB-9-inventory-drop-two-clicks](KB-9-inventory-drop-two-clicks.md)), move the floating icon to a
   clear dark area, screenshot, and read it: the dragged widget renders at the cursor and the source
   cell empties, so you see *which* item you grabbed. Wrong one? Click it back onto the grid
   (dropping into the source is a no-op) and try again.

GUI coordinates are camera-independent and stable across runs given a **fresh default-layout
profile** (the rig wipes it each run) and a **fixed fixture inventory** (item sort order is
deterministic). A coordinate found once is reusable, with no per-run re-detection.
