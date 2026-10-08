# KB-21-server-pushed-console-command — Push console commands from the server: a typed one gets the client kicked
Read when: a test needs to set up game state with a console command (MWScript or `lua …`) on a multiplayer client, or a client was kicked right after a console command or right after the object it placed.

**Confidence: VALIDATED** (OpenMW 0.51-based TES3MP client and server, stock CoreScripts)

**The rule.** In multiplayer, never type a console command into a client (xdotool into the console
window, or a startup script). Have the **server** send it. Stock CoreScripts validate every console
command a client reports (`OnConsoleCommand` in `scripts/eventHandler.lua`): unless the player is
allowed the console (`config.allowConsole`, off by default) or the server queued that exact command
for that player, the server logs `Rejected ConsoleCommand from <p> … and kicked them` and kicks the
client.

**How the server sends one.** `logicHandler.RunConsoleCommandOnPlayer(pid, cmd, false)` adds the
command to `Players[pid].consoleCommandsQueued` and sends it in an `ID_CONSOLE_COMMAND` packet. The
client runs it through its console with the player as the selected object, so an MWScript command
without an explicit reference acts on the player. `RunConsoleCommandOnObjects(pid, cmd, cell,
{"<refnum>-<mpnum>"}, false)` runs it on an object of a cell instead.

**What the logs show for an MWScript command** (`ModCurrentFatigue -50`):

- client: `Received ID_CONSOLE_COMMAND about <cell>` then ` Console command: ModCurrentFatigue -50`;
- the client reports the command back (every MWScript console command is echoed to the server), and
  the server logs `Accepted ConsoleCommand from <p> (<pid>) about <cell>` with
  `- was a console command executed at the server's request`. That line is the proof it was not
  kicked.

**`lua …` commands never reach the validator** (OpenMW ≥ 0.48). The client console hands any command
starting with `lua` to the Lua console handlers (every player script's `onConsoleCommand(mode,
command, selected)`) and returns *before* the multiplayer echo, so the server sees no
`OnConsoleCommand` for it. A player script can therefore take requests from the server as
`lua <word> <args>`. The built-in console script prints a usage hint into the in-game console for
`lua` followed by an unknown word; that is harmless.

**In the rig.** The `console`, `console-file`, `console-object` and `probe` verbs do exactly this
through the rig's server bridge (`overlay/scripts/custom/rig-bridge.lua`; file protocol and verbs:
[SCENARIO-FORMAT.md](../SCENARIO-FORMAT.md) §3.4 and §8). The bridge logs
`[rig-bridge] <seq> console <p>: <cmd>` when it sends; assert the command's effect separately — a
sent command is not yet an executed one:

```
probe a stats
console a "ModCurrentFatigue -50"
probe a stats
assert probe-delta a stats fat '<' -20      # fat 100 -> 50: the command ran on a
assert absent server 'kicked'
```

Console commands and probe requests to the same player travel the same ordered channel, so a
`probe` right after a `console` sees the command's **synchronous** effect: one the client applies
while it runs the command (`ModCurrentFatigue` changes fatigue inside the packet handler). An effect
that needs a round trip through the server, or a later frame, is not there yet: `placeatpc` (the
object exists once the server echoes its ObjectPlace), `journal` as another player sees it (the
server shares it), `playgroup` (starts on the next frame). Wait for its server or client line, or `settle`, before probing it.

**Commands that create or change objects need the console permission too.** The queued-command
exemption covers only the command's own echo (`OnConsoleCommand`, stock
`scripts/eventHandler.lua:164`). An object packet the command then causes carries the console as
its origin (`placeatpc` sends an ObjectPlace), and the handler shared by every object packet kicks a
player who is not allowed the console, whether or not the server queued the command
(`eventHandler.lua:1379`, `OnGenericObjectEvent`; container packets have the same check at
`:1571`). Give that one player the console first, through the bridge's `lua` verb; the server
configuration stays stock:

```
server f "player.data.settings.consoleAllowed = true"      # per player, as a staff member has it
console f "placeatpc some_item 1 0 0"
wait server 'Accepted ObjectPlace from f' 8
```

`logicHandler.IsPlayerAllowedConsole` (stock `scripts/logicHandler.lua:157`) is true for an admin or
a player whose `data.settings.consoleAllowed` is `true`. The value is saved with the player record;
in a rig run that is the run's throwaway work copy, so the fixture is unchanged.

**Dead ends.**

- *Typing the command* with the console open: kicked as above (no `allowConsole`).
- *Turning on `config.allowConsole`* to avoid the kick: it changes the server under test for every
  player, and a scenario then passes on a server configuration nobody plays. The per-player
  `consoleAllowed` above is the narrow form.
- *Expecting the server to undo a stat change made by a console command*: it does not. The client is
  authoritative for its own health, magicka and fatigue and reports them to the server, which stores
  the reported values (stock `eventHandler.lua:664,994`, on disconnect and cell change); the server
  pushes dynamic stats to the client only at login or when a server script sets them. A
  `ModCurrentFatigue` pushed through `console` therefore sticks.
