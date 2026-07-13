-- example-suite-compat.lua
--
-- Make stock TES3MP CoreScripts survive on OpenMW's free example-suite content (template.omwgame),
-- which is NOT Morrowind. Two content assumptions in CoreScripts otherwise crash the server the
-- moment a player finishes character generation:
--
--   clientVariableScopes.globals is built up ONLY inside `if clientDataFiles contains Morrowind.esm`
--   (and Tribunal/Bloodmoon) blocks in scripts/clientVariableScopes.lua. On example-suite none of
--   those load, so globals stays `{}` and logicHandler.SendClientScriptSettings() does
--   `pairs(clientVariableScopes.globals["personal"])` -> "bad argument #1 to 'pairs' (table expected,
--   got nil)" -> "Server crash from script error!" on OnPlayerConnect.
--
-- Fix: after the default OnServerPostInit handler has required clientVariableScopes, ensure every
-- category logicHandler/eventHandler dereferences exists as (at least) an empty table. This is
-- purely additive — on real Morrowind data the categories are already populated, so `x or {}` leaves
-- them untouched; it only supplies empty defaults when the content isn't Morrowind.
--
-- Loaded via the overlay scripts/customScripts.lua that the example runner points the server at
-- (a runtime work-copy of CoreScripts; the shared clone is never modified).

customEventHooks.registerHandler("OnServerPostInit", function()
    -- Categories dereferenced by logicHandler.SendClientScriptSettings (line ~403) and by
    -- eventHandler's global-variable sync classification (globals.ignored / kills / quest /
    -- factionRanks / factionExpulsion / worldwide). "unknown" is used by some CoreScripts revisions.
    local categories = {"ignored", "personal", "quest", "kills",
                        "factionRanks", "factionExpulsion", "worldwide", "unknown"}

    if type(clientVariableScopes) ~= "table" then clientVariableScopes = {} end
    if type(clientVariableScopes.globals) ~= "table" then clientVariableScopes.globals = {} end

    local filled = {}
    for _, cat in ipairs(categories) do
        if type(clientVariableScopes.globals[cat]) ~= "table" then
            clientVariableScopes.globals[cat] = {}
            filled[#filled + 1] = cat
        end
    end

    if #filled > 0 then
        tes3mp.LogMessage(enumerations.log.INFO,
            "[example-suite-compat] filled empty clientVariableScopes.globals categories: " ..
            table.concat(filled, ", "))
    end
end)
