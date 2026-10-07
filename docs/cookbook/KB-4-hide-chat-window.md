# KB-4-hide-chat-window — Hide the chat/welcome window: right after login, after any chat commands
Read when: the first click after login is lost, or a chat command sent mid-run does nothing.

**Confidence: VALIDATED**

A chat-toggle key (often **F2**, or **F6** on some CoreScripts configurations) hides the chat/welcome
window. Do it right after login so the window can't eat the first cast click
([KB-1-synthetic-left-click-cast](KB-1-synthetic-left-click-cast.md)); allow ~1 s to settle. Once
hidden it stays hidden for the session.

A fully hidden (disabled) chat window **won't reopen** on the say key, so a chat command sent *after*
hiding it is silently dropped. Send chat commands before hiding, or log values from a server-side
hook instead (see [FEATURE-TESTS](../FEATURE-TESTS.md)).
