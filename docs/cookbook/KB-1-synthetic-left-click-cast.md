# KB-1-synthetic-left-click-cast — Cast with a synthetic left click: the button works, the cast is what fails
Read when: a headless cast or attack click seems not to register.

**Confidence: VALIDATED**

`xdotool mousedown 1; sleep 0.2; xdotool mouseup 1` casts the readied spell or scroll. A plain
`xdotool click 1` also works; the brief held press is a safe default, not a requirement.

**The reliability lever is the cast, not the button:**
- A **spell** has a skill-based **cast chance**. A low-skill caster *fizzles* most attempts, which
  looks exactly like input failure but isn't. To cast reliably, use a **scroll** (always succeeds, no
  skill check, no magicka cost), or raise the skill in the fixture or from the console first; then the
  only limit is magicka.
- The chat/welcome window **eats the first click** after login (it is a focusable window). Hide it
  first ([KB-4-hide-chat-window](KB-4-hide-chat-window.md)).

There is **no** need to rebind the use action to a keyboard key; synthetic mouse buttons register as
a cast. Keep a keyboard rebind of the use action (a seeded `input_v3.xml`) only as a fallback if an
engine build regresses synthetic buttons.

Dead end: concluding "a held press works, a click doesn't" from a fizzling low-skill spell. See
[KB-5-rule-out-game-logic-confounds](KB-5-rule-out-game-logic-confounds.md).
