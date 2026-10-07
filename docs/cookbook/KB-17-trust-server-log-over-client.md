# KB-17-trust-server-log-over-client — Gate on the server's log line, not the client's: client stdout is block-buffered
Read when: gating a retry, a wait or a screenshot on an event that both the server and a client log.

**Confidence: VALIDATED** (the loading-screen note: **THEORY**)

When both sides log an event, gate on the **server's** line (for a cell change,
`Adding <cell> to Player <P>`), never the client's own stdout. A headless client's stdout is
**block-buffered under redirection** and can lag many seconds. A false "the door did not activate"
then makes a retry turn the player *away* from an already-open door. The server's line is fresh; the
client's is not.

This is also why you **poll** a logged value rather than grepping once: buffered output flushes in
batches (see [FEATURE-TESTS](../FEATURE-TESTS.md), "Poll logged values").

**The server event precedes the client's render (THEORY).** A server cell-change line can arrive
before the client has finished loading the cell, so a grab right after it can catch the loading
screen (slow software GL makes this likelier). Put a screen-stability wait
([KB-15-screen-stability-wait](KB-15-screen-stability-wait.md)) between the server event and the
grab.
