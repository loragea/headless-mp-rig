# KB-2-scroll-quick-key-read-parchment — Cast a scroll from a quick-key: close the read-parchment only out of combat
Read when: scripting a scroll cast, or a scroll cast works in one phase of a scenario and not in another.

**Confidence: VALIDATED**

A quick-key (`1`–`0`) **equips and uses** the bound scroll; the server logs
`<player> used inventory item <id>`.
- **Out of combat:** it opens the **read parchment**. Close it with **`space`**, then cast
  ([KB-1-synthetic-left-click-cast](KB-1-synthetic-left-click-cast.md)).
- **In combat:** reading is blocked (the HUD shows "You cannot read during battle"), so there is **no
  parchment and no `space`**. Just cast.

So a scroll cast *before* combat needs the `space`; one cast *during* combat must not include it.
Don't blindly `space` every scroll.
