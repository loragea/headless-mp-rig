# KB-3-spell-hit-turns-npc-hostile — Turn an NPC hostile with a spell hit: the hit's log chain proves combat began
Read when: a scenario needs an NPC in combat, or needs logged proof that combat started.

**Confidence: VALIDATED**

A spell or scroll **hit** on an NPC drives it hostile through server-side AI, run by the
cell-authority client. The server logs `ID_OBJECT_HIT`, a hit sound, and active-spell lines
(`OnActorSpellsActive`) on the NPC. Afterwards, player input shows the "cannot read during battle"
gate ([KB-2-scroll-quick-key-read-parchment](KB-2-scroll-quick-key-read-parchment.md)), which
means the player is now in combat.

The NPC's visible combat stance is a good checkpoint for the observing player, best taken as a
differential pair ([KB-8-differential-motion-screenshots](KB-8-differential-motion-screenshots.md)).
