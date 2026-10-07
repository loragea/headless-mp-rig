-- rig-bridge.lua — the headless rig's server-side helper.
--
-- lib/rig.sh (rig_corescripts_overlay) copies this into every run's throwaway CoreScripts work copy
-- and loads it through scripts/customScripts.lua.append, so the user's CoreScripts clone is never
-- edited. This version only logs anchor lines a test can wait on; it does not execute commands yet.
--
-- Every line starts with "[rig-bridge]" at INFO level, so a scenario can exclude or match them with
-- one pattern.

local rigBridge = {}

local function log(text)
    tes3mp.LogMessage(enumerations.log.INFO, "[rig-bridge] " .. text)
end

-- Names the data dir the server actually uses: proof that the run's work copy (not the user's clone)
-- is the server home.
customEventHooks.registerHandler("OnServerPostInit", function(eventStatus)
    log("loaded; data path " .. tostring(config.dataPath))
end)

customEventHooks.registerHandler("OnPlayerAuthentified", function(eventStatus, pid)
    log("player " .. tostring(tes3mp.GetName(pid)) .. " in (pid " .. tostring(pid) .. ")")
end)

customEventHooks.registerHandler("OnPlayerDisconnect", function(eventStatus, pid)
    log("player " .. tostring(tes3mp.GetName(pid)) .. " out (pid " .. tostring(pid) .. ")")
end)

return rigBridge
