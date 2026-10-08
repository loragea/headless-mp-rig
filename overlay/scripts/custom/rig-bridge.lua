-- rig-bridge.lua — the headless rig's server-side helper.
--
-- lib/rig.sh (rig_corescripts_overlay) copies this into every run's throwaway CoreScripts work copy
-- and loads it through scripts/customScripts.lua.append, so the user's CoreScripts clone is never
-- edited. It does two things:
--
--   1. Logs anchor lines a test can wait on (every line starts with "[rig-bridge]", INFO level):
--        [rig-bridge] loaded; data path <dir>
--        [rig-bridge] player <name> in (pid N)      [rig-bridge] player <name> out (pid N)
--
--   2. Executes commands the test runner drops into a command directory, named by the server's
--      environment variable RIG_BRIDGE_DIR (unset = commands off). The file protocol:
--        cmd-<seq>.meta   one line, tab-separated: <verb> <player> <arg>...   (written atomically)
--        cmd-<seq>.lua    the Lua body of a `lua` command
--      seq counts up from 1; the bridge executes seq 1, 2, 3 ... in order and answers each with
--        done-<seq>       "<detail>"          the command ran (for console/probe: was sent to the client)
--        err-<seq>        "<message>"         it did not run (player not logged in, Lua error, ...)
--      Verbs:
--        console <player> <mwscript>            logicHandler.RunConsoleCommandOnPlayer(pid, cmd, false)
--        object <player> <cell> <refnum-mpnum> <mwscript>   ...RunConsoleCommandOnObjects on that object
--        probe <player> <kind>                  sends "lua rigprobe <kind> <seq>" to the client probe
--        lua <player>                           runs cmd-<seq>.lua with `pid` and `player` bound
--        save <player>                          Players[pid]:SaveToDrive()
--        savecell - <cell description>          LoadedCells[cell]:SaveToDrive()
--      Console commands must be queued by the server: a client that runs a console command the
--      server did not queue is kicked by stock CoreScripts (OnConsoleCommand validator), unless
--      config.allowConsole is on. Commands starting with "lua" never reach that validator: the client
--      hands them to its Lua console handlers before it echoes MWScript commands to the server.
--
-- Globals: RigBridgePoll only — TES3MP timers call a global function by name.

local rigBridge = {}

local POLL_MS = 250
local DRAIN_PER_TICK = 20

local bridgeDir = os.getenv("RIG_BRIDGE_DIR")
if bridgeDir == "" then bridgeDir = nil end
local nextSeq = 1
local timerId = nil

local function log(text)
    tes3mp.LogMessage(enumerations.log.INFO, "[rig-bridge] " .. text)
end

local function oneLine(s)
    return (tostring(s):gsub("[\r\n\t]+", " "))
end

local function readFile(path)
    local f = io.open(path, "r")
    if f == nil then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function reply(seq, ok, text)
    local name = (ok and "done-" or "err-") .. seq
    local tmp = bridgeDir .. "/." .. name .. ".tmp"
    local f = io.open(tmp, "w")
    if f == nil then
        log(seq .. " cannot write " .. tmp)
        return
    end
    f:write(oneLine(text or ""), "\n")
    f:close()
    os.rename(tmp, bridgeDir .. "/" .. name)
end

local function splitTabs(line)
    local fields = {}
    for field in (line .. "\t"):gmatch("([^\t]*)\t") do fields[#fields + 1] = field end
    return fields
end

local function pidOf(name)
    if name == nil then return nil end
    for pid, player in pairs(Players) do
        if player ~= nil and player.accountName ~= nil and string.lower(player.accountName) == string.lower(name)
            and player:IsLoggedIn() then
            return pid
        end
    end
    return nil
end

local function compile(body, chunkName, env)
    if setfenv ~= nil and loadstring ~= nil then
        local fn, err = loadstring(body, chunkName)
        if fn ~= nil then setfenv(fn, env) end
        return fn, err
    end
    return load(body, chunkName, "t", env)
end

-- Each handler returns ok, detail.
local handlers = {}

handlers.console = function(seq, pid, f)
    if f[3] == nil or f[3] == "" then return false, "no console command" end
    if f[4] ~= nil then return false, "the command holds a tab (it would run only up to the tab)" end
    logicHandler.RunConsoleCommandOnPlayer(pid, f[3], false)
    return true, "sent to pid " .. pid
end

handlers.object = function(seq, pid, f)
    local cell, index, cmd = f[3], f[4], f[5]
    if cell == nil or cell == "" or index == nil or not index:match("^%d+%-%d+$") or cmd == nil or cmd == "" then
        return false, "expected <cell> <refnum-mpnum> <command>"
    end
    if f[6] ~= nil then return false, "the command holds a tab (it would run only up to the tab)" end
    logicHandler.RunConsoleCommandOnObjects(pid, cmd, cell, { index }, false)
    return true, "sent to pid " .. pid .. " for " .. index .. " in " .. cell
end

handlers.probe = function(seq, pid, f)
    local kind = f[3]
    if kind == nil or not kind:match("^[%w_]+$") then return false, "bad probe kind" end
    logicHandler.RunConsoleCommandOnPlayer(pid, "lua rigprobe " .. kind .. " " .. seq, false)
    return true, "sent to pid " .. pid
end

handlers.lua = function(seq, pid, f)
    local body = readFile(bridgeDir .. "/cmd-" .. seq .. ".lua")
    if body == nil then return false, "no cmd-" .. seq .. ".lua" end
    local env = setmetatable({ pid = pid, player = Players[pid] }, { __index = _G })
    local fn, err = compile(body, "=rig-cmd-" .. seq, env)
    if fn == nil then return false, "compile: " .. tostring(err) end
    local ok, res = pcall(fn)
    if not ok then return false, "runtime: " .. tostring(res) end
    if res ~= nil then return true, "returned " .. tostring(res) end
    return true, "ran"
end

handlers.save = function(seq, pid, f)
    Players[pid]:SaveToDrive()
    return true, "saved player " .. tostring(Players[pid].accountName)
end

-- savecell needs no player: its <player> field is "-".
handlers.savecell = function(seq, pid, f)
    local cell = f[3]
    if cell == nil or cell == "" then return false, "no cell" end
    if LoadedCells[cell] == nil then return false, "cell " .. cell .. " is not loaded" end
    LoadedCells[cell]:SaveToDrive()
    return true, "saved cell " .. cell
end

local NO_PLAYER = { savecell = true }

local function run(seq, meta)
    local f = splitTabs((meta:gsub("[\r\n]+$", "")))
    local verb, who = f[1], f[2]
    local handler = handlers[verb]
    log(seq .. " " .. tostring(verb) .. " " .. tostring(who) .. ": " .. oneLine(table.concat(f, " ", 3)))
    if handler == nil then
        log(seq .. " error: unknown verb")
        reply(seq, false, "unknown verb " .. tostring(verb))
        return
    end
    local pid = nil
    if not NO_PLAYER[verb] then
        pid = pidOf(who)
        if pid == nil then
            log(seq .. " error: player " .. tostring(who) .. " is not logged in")
            reply(seq, false, "player " .. tostring(who) .. " is not logged in")
            return
        end
    end
    local okCall, ok, detail = pcall(handler, seq, pid, f)
    if not okCall then ok, detail = false, "failed: " .. tostring(ok) end
    log(seq .. (ok and " done: " or " error: ") .. oneLine(detail))
    reply(seq, ok, detail)
end

local function poll()
    for _ = 1, DRAIN_PER_TICK do
        local meta = readFile(bridgeDir .. "/cmd-" .. nextSeq .. ".meta")
        if meta == nil then return end
        local seq = nextSeq
        nextSeq = nextSeq + 1
        run(seq, meta)
    end
end

-- The timer callback. tes3mp timers are one-shot: re-arm it every time.
function RigBridgePoll()
    local ok, err = pcall(poll)
    if not ok then log("poll failed: " .. oneLine(err)) end
    tes3mp.RestartTimer(timerId, POLL_MS)
end

-- Names the data dir the server actually uses: proof that the run's work copy (not the user's clone)
-- is the server home.
customEventHooks.registerHandler("OnServerPostInit", function(eventStatus)
    log("loaded; data path " .. tostring(config.dataPath))
    if bridgeDir == nil then
        log("commands off (RIG_BRIDGE_DIR is not set)")
        return
    end
    timerId = tes3mp.CreateTimer("RigBridgePoll", POLL_MS)
    tes3mp.StartTimer(timerId)
    log("commands from " .. bridgeDir)
end)

customEventHooks.registerHandler("OnPlayerAuthentified", function(eventStatus, pid)
    log("player " .. tostring(tes3mp.GetName(pid)) .. " in (pid " .. tostring(pid) .. ")")
end)

customEventHooks.registerHandler("OnPlayerDisconnect", function(eventStatus, pid)
    log("player " .. tostring(tes3mp.GetName(pid)) .. " out (pid " .. tostring(pid) .. ")")
end)

return rigBridge
