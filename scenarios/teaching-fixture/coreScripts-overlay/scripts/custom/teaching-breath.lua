-- teaching-breath.lua — give every player water breathing the moment they log in.
--
-- The example-suite world has no landscape: every exterior cell is a flat floor about 2000 units
-- under the water plane, so a player drowns within ~25 s of logging in and revives at a random
-- spot, which wrecks any position, frame or probe assertion.
--
-- The scenarios/example fixture solves this with a permanent active spell in each player save. That
-- spell has no record in template.omwgame, and its effect's hit visual (VFX_DefaultHit) does not
-- exist either, so every client logs "Error in frame: Static VFX_DefaultHit not found" on every
-- frame and the frame's world update is cut short: players cannot walk or turn. This fixture's saves
-- carry no active spell; instead the server pushes the console command `SetWaterBreathing 1` to the
-- player at login. It sets the effect's magnitude directly (no spell, no visual), and the client
-- probe reports it (`probe <p> effects` -> effect=waterbreathing).
--
-- RunConsoleCommandOnPlayer queues the command, so the client's echo of it passes the server's
-- console check without the player needing console permission (cookbook KB-21).

customEventHooks.registerHandler("OnPlayerAuthentified", function(eventStatus, pid)
    if Players[pid] == nil then return end
    logicHandler.RunConsoleCommandOnPlayer(pid, "SetWaterBreathing 1", false)
    tes3mp.LogMessage(enumerations.log.INFO, "[teaching-breath] water breathing pushed to " ..
        Players[pid].accountName)
end)
