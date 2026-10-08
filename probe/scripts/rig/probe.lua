-- probe.lua — the headless rig's client probe (an OpenMW Lua PLAYER script, OpenMW >= 0.48).
--
-- Prints engine state as one-line records into the client log (Lua `print` -> the engine log at
-- Info level), so a test can assert on what this client's engine holds. Read-only by design: it
-- never sets controls, teleports, or changes any state.
--
-- Line format (docs/SCENARIO-FORMAT.md, "Probe lines"):
--   [rigprobe:<kind>] p=<player> t=<simulation time> seq=<n> key=value ...
-- A value holding spaces is "quoted"; a double quote inside a value is replaced by '.
-- seq=<n> echoes the request that produced the line; seq=0 marks a heartbeat or event line.
-- A request ends with [rigprobe:done] ... seq=<n> kind=<kind> lines=<count>.
--
-- Triggers:
--   * the console command `lua rigprobe <kind|dump> <seq>`, pushed by the server (the rig's bridge);
--   * events: quest update -> quest, cell change -> cell, inventory change (checked every 2 s) -> inv;
--   * a heartbeat every `period` real seconds: cell + stats.
-- The first frame of a running simulation prints [rigprobe:ready] with caps=<the kinds and fields
-- this engine supports>;
-- each binding is tried under pcall, and a missing one is left out of caps.

local self = require('openmw.self')
local core = require('openmw.core')
local types = require('openmw.types')
local nearby = require('openmw.nearby')
local hasAnimation, animation = pcall(require, 'openmw.animation')

local VERSION = 1
-- Per-run settings, written by the rig next to this file (scripts/rig/probe_conf.lua).
local conf = { period = 5, range = 2048, off = '' }
do
    local ok, c = pcall(require, 'scripts.rig.probe_conf')
    if ok and type(c) == 'table' then
        for k, v in pairs(c) do conf[k] = v end
    end
end
local disabled = {}
for name in string.gmatch(tostring(conf.off or ''), '[%w_]+') do disabled[name] = true end

local INV_LIMIT = 40
local NEARBY_LIMIT = 80
local LIST_LIMIT = 80     -- items, effects, faction, spells: lines per request

-- ---------------------------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------------------------
local function fmt(v)
    if v == nil then return '""' end
    local t = type(v)
    if t == 'boolean' then return v and '1' or '0' end
    if t == 'number' then
        if v ~= v then return 'nan' end
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format('%d', v) end
        return string.format('%.2f', v)
    end
    local s = tostring(v):gsub('"', "'"):gsub('[%c]', ' ')
    if s == '' or s:find('%s') then return '"' .. s .. '"' end
    return s
end

local function get(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

local function round(x) if x == nil then return nil end return math.floor(x + 0.5) end

local function playerName()
    return get(function() return types.NPC.record(self.object).name end) or '?'
end

local function emit(kind, seq, fields)
    local parts = { '[rigprobe:' .. kind .. ']', 'p=' .. fmt(playerName()),
                    't=' .. fmt(get(core.getSimulationTime) or 0), 'seq=' .. tostring(seq) }
    for i = 1, #fields, 2 do
        local v = fields[i + 1]
        if v ~= nil then parts[#parts + 1] = fields[i] .. '=' .. fmt(v) end
    end
    print(table.concat(parts, ' '))
end

-- ---------------------------------------------------------------------------------------------
-- Capabilities
-- ---------------------------------------------------------------------------------------------
-- A cap is present when its bindings exist in this engine. The test looks at the API, not at a value:
-- on the first frame the player may have no cell yet, and weather needs an active cell.
local caps, capList = {}, {}
local function isFn(f) return type(f) == 'function' end
local CAP_TESTS = {
    { 'cell',    function() local _ = self.cell; return self.position ~= nil end },
    { 'stats',   function() return isFn(types.Actor.stats.dynamic.health) and isFn(types.Actor.stats.level) end },
    { 'stance',  function() return isFn(types.Actor.getStance) and types.Actor.STANCE ~= nil end },
    { 'quest',   function() return isFn(types.Player.quests) end },
    { 'topics',  function() return isFn(types.Player.journal) and types.Player.journal(self).topics ~= nil end },
    { 'inv',     function() return isFn(types.Actor.inventory) end },
    { 'nearby',  function() return nearby.actors ~= nil and nearby.doors ~= nil and nearby.containers ~= nil end },
    { 'items',   function() return nearby.items ~= nil end },
    { 'effects', function() return isFn(types.Actor.activeSpells) and isFn(types.Actor.activeEffects) end },
    { 'faction', function() return isFn(types.NPC.getFactions) and isFn(types.NPC.getFactionRank) end },
    { 'spells',  function() return isFn(types.Actor.spells) end },
    { 'dead',    function() return isFn(types.Actor.isDead) end },
    { 'deathdone', function() return isFn(types.Actor.isDeathFinished) end },
    { 'equip',   function() return isFn(types.Actor.getEquipment) and types.Actor.EQUIPMENT_SLOT ~= nil end },
    { 'anim',    function() return hasAnimation and isFn(animation.getActiveGroup) and animation.BONE_GROUP ~= nil end },
    { 'lock',    function() return isFn(types.Lockable.getLockLevel) and isFn(types.Lockable.isLocked) end },
    { 'time',    function() return isFn(core.getGameTime) end },
    { 'weather', function() return core.weather ~= nil and isFn(core.weather.getCurrent) end },
}
local function detectCaps()
    caps, capList = {}, {}
    for _, t in ipairs(CAP_TESTS) do
        local name, test = t[1], t[2]
        if not disabled[name] then
            local ok, v = pcall(test)
            if ok and v then
                caps[name] = true
                capList[#capList + 1] = name
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Kinds: each emits its lines and returns how many
-- ---------------------------------------------------------------------------------------------
local stanceNames = {}
pcall(function() for k, v in pairs(types.Actor.STANCE) do stanceNames[v] = string.lower(k) end end)
local function stanceOf(actor)
    if not caps.stance then return nil end
    local s = get(types.Actor.getStance, actor)
    if s == nil then return nil end
    return stanceNames[s] or s
end
local function animOf(actor, group)
    if not caps.anim then return nil end
    local g = get(animation.getActiveGroup, actor, animation.BONE_GROUP[group])
    if g == nil or g == '' then return 'none' end
    return g
end
local function deadOf(actor)
    if not caps.dead then return nil end
    return get(types.Actor.isDead, actor)
end
local function deathDoneOf(actor)
    if not caps.deathdone then return nil end
    return get(types.Actor.isDeathFinished, actor)
end
local function weaponOf(actor)
    if not caps.equip then return nil end
    local ok, w = pcall(types.Actor.getEquipment, actor, types.Actor.EQUIPMENT_SLOT.CarriedRight)
    if not ok then return nil end
    if w == nil then return 'none' end
    return get(function() return w.recordId end)
end
local function idOf(v)
    if v == nil then return nil end
    if type(v) == 'string' then return v end
    return get(function() return v.id end) or tostring(v)
end
local function dyn(actor, which)
    local s = get(function() return types.Actor.stats.dynamic[which](actor) end)
    if s == nil then return nil, nil end
    return round(s.current), round(s.base)
end

local kinds = {}

kinds.cell = function(seq)
    local c, pos = self.cell, self.position
    local ext = get(function() return c.isExterior end)
    emit('cell', seq, {
        'cell', get(function() return c.name end) or '',
        'id', get(function() return c.id end),
        'x', round(pos.x), 'y', round(pos.y), 'z', round(pos.z),
        'exterior', ext,
        'gridx', ext and get(function() return c.gridX end) or nil,
        'gridy', ext and get(function() return c.gridY end) or nil,
    })
    return 1
end

kinds.stats = function(seq)
    local hp, hpbase = dyn(self, 'health')
    local mp, mpbase = dyn(self, 'magicka')
    local fat, fatbase = dyn(self, 'fatigue')
    emit('stats', seq, {
        'hp', hp, 'hpbase', hpbase, 'mp', mp, 'mpbase', mpbase, 'fat', fat, 'fatbase', fatbase,
        'level', get(function() return types.Actor.stats.level(self).current end),
        'stance', stanceOf(self),
        'dead', deadOf(self),
        'deathdone', deathDoneOf(self),
    })
    return 1
end

kinds.quest = function(seq)
    local n = 0
    for id, q in pairs(types.Player.quests(self)) do
        emit('quest', seq, { 'id', id, 'stage', get(function() return q.stage end),
                             'finished', get(function() return q.finished end) })
        n = n + 1
    end
    return n
end

kinds.topics = function(seq)
    local ids = {}
    for id in pairs(types.Player.journal(self).topics) do ids[#ids + 1] = id end
    table.sort(ids)
    emit('topics', seq, { 'n', #ids })
    for _, id in ipairs(ids) do emit('topics', seq, { 'topic', id }) end
    return #ids + 1
end

local function inventoryCounts()
    local counts = {}
    for _, item in ipairs(types.Actor.inventory(self):getAll()) do
        local id = item.recordId
        counts[id] = (counts[id] or 0) + (item.count or 1)
    end
    local ids = {}
    for id in pairs(counts) do ids[#ids + 1] = id end
    table.sort(ids)
    return counts, ids
end

kinds.inv = function(seq)
    local counts, ids = inventoryCounts()
    emit('inv', seq, { 'n', #ids, 'more', #ids > INV_LIMIT })
    for i, id in ipairs(ids) do
        if i > INV_LIMIT then break end
        emit('inv', seq, { 'item', id .. ':' .. counts[id], 'id', id, 'count', counts[id] })
    end
    return math.min(#ids, INV_LIMIT) + 1
end

local function actorKind(a)
    if get(types.Player.objectIsInstance, a) then return 'player' end
    if get(types.NPC.objectIsInstance, a) then return 'npc' end
    if get(types.Creature.objectIsInstance, a) then return 'creature' end
    return 'actor'
end
local function recordName(obj, kind)
    local t = ({ player = types.NPC, npc = types.NPC, creature = types.Creature, door = types.Door,
                 container = types.Container })[kind]
    if t == nil then return nil end
    return get(function() return t.record(obj).name end)
end

kinds.nearby = function(seq)
    local here = self.position
    local rows = {}
    for _, a in ipairs(nearby.actors) do
        if a ~= self.object then
            local d = (a.position - here):length()
            if d <= conf.range then
                local kind = actorKind(a)
                local pos = a.position
                rows[#rows + 1] = { d, 'actor', {
                    'actor', recordName(a, kind) or a.recordId, 'rec', a.recordId, 'dist', round(d), 'kind', kind,
                    'x', round(pos.x), 'y', round(pos.y), 'z', round(pos.z),
                    'stance', stanceOf(a), 'anim', animOf(a, 'LowerBody'), 'animup', animOf(a, 'Torso'),
                    'hp', (dyn(a, 'health')), 'dead', deadOf(a), 'weapon', weaponOf(a) } }
            end
        end
    end
    local function lockables(list, kind)
        for _, o in ipairs(list) do
            local d = (o.position - here):length()
            if d <= conf.range then
                local f = { 'obj', o.recordId, 'name', recordName(o, kind), 'kind', kind, 'dist', round(d) }
                if caps.lock then
                    f[#f + 1] = 'lock'; f[#f + 1] = get(types.Lockable.getLockLevel, o)
                    f[#f + 1] = 'locked'; f[#f + 1] = get(types.Lockable.isLocked, o)
                end
                rows[#rows + 1] = { d, 'obj', f }
            end
        end
    end
    lockables(nearby.doors, 'door')
    lockables(nearby.containers, 'container')
    table.sort(rows, function(x, y) return x[1] < y[1] end)
    local n = 0
    for _, r in ipairs(rows) do
        if n >= NEARBY_LIMIT then break end
        emit('nearby', seq, r[3])
        n = n + 1
    end
    return n
end

-- Items lying in the active cells (not in containers or inventories), nearest first.
kinds.items = function(seq)
    local here = self.position
    local rows = {}
    for _, o in ipairs(nearby.items) do
        local pos = o.position
        local d = (pos - here):length()
        if d <= conf.range then
            rows[#rows + 1] = { d, { 'obj', o.recordId, 'name', get(function() return o.type.record(o).name end),
                                     'count', get(function() return o.count end), 'dist', round(d),
                                     'x', round(pos.x), 'y', round(pos.y), 'z', round(pos.z) } }
        end
    end
    table.sort(rows, function(x, y) return x[1] < y[1] end)
    local n = 0
    for _, r in ipairs(rows) do
        if n >= LIST_LIMIT then break end
        emit('items', seq, r[2])
        n = n + 1
    end
    return n
end

-- The player's active spells (one line each, then one per applied effect of it) and the summed
-- active effects (net=1).
kinds.effects = function(seq)
    local n = 0
    local function line(fields)
        if n >= LIST_LIMIT then return end
        emit('effects', seq, fields)
        n = n + 1
    end
    for _, sp in pairs(types.Actor.activeSpells(self)) do
        local id = get(function() return sp.id end)
        local caster = get(function() return sp.caster end)
        line({ 'spell', id, 'name', get(function() return sp.name end),
               'caster', caster and get(function() return caster.recordId end) or nil,
               'castername', caster and recordName(caster, actorKind(caster)) or nil })
        for _, e in pairs(get(function() return sp.effects end) or {}) do
            line({ 'spell', id, 'effect', idOf(get(function() return e.id end)),
                   'mag', get(function() return e.magnitudeThisFrame end),
                   'left', get(function() return e.durationLeft end) })
        end
    end
    for _, e in pairs(types.Actor.activeEffects(self)) do
        line({ 'net', 1, 'effect', idOf(get(function() return e.id end)), 'mag', get(function() return e.magnitude end) })
    end
    return n
end

kinds.faction = function(seq)
    local ids = {}
    for _, id in pairs(types.NPC.getFactions(self)) do ids[#ids + 1] = tostring(id) end
    table.sort(ids)
    emit('faction', seq, { 'n', #ids })
    for i, id in ipairs(ids) do
        if i > LIST_LIMIT then break end
        emit('faction', seq, { 'faction', id, 'rank', get(types.NPC.getFactionRank, self, id) })
    end
    return math.min(#ids, LIST_LIMIT) + 1
end

kinds.spells = function(seq)
    local rows = {}
    for _, sp in pairs(types.Actor.spells(self)) do
        rows[#rows + 1] = { get(function() return sp.id end) or '?', get(function() return sp.name end) }
    end
    table.sort(rows, function(x, y) return x[1] < y[1] end)
    emit('spells', seq, { 'n', #rows })
    for i, r in ipairs(rows) do
        if i > LIST_LIMIT then break end
        emit('spells', seq, { 'spell', r[1], 'name', r[2] })
    end
    return math.min(#rows, LIST_LIMIT) + 1
end

kinds.time = function(seq)
    local gt = core.getGameTime()
    emit('time', seq, { 'gametime', round(gt), 'hour', (gt / 3600) % 24, 'day', math.floor(gt / 86400),
                        'scale', get(core.getGameTimeScale) })
    return 1
end

kinds.weather = function(seq)
    local function id(w) if w == nil then return 'none' end return get(function() return w.recordId end) or tostring(w) end
    -- The weather getters take the cell; an interior has no weather ("none").
    local c = self.cell
    emit('weather', seq, { 'weather', id(get(core.weather.getCurrent, c)), 'next', id(get(core.weather.getNext, c)),
                           'transition', get(core.weather.getTransition, c) })
    return 1
end

local ORDER = { 'cell', 'stats', 'quest', 'topics', 'inv', 'nearby', 'items', 'effects', 'faction', 'spells',
                'time', 'weather' }

local function runKind(kind, seq)
    if not caps[kind] then return 0, kind end
    local ok, n = pcall(kinds[kind], seq)
    if ok then return n, nil end
    emit('error', seq, { 'kind', kind, 'msg', tostring(n) })
    return 1, nil
end

local function request(kind, seq)
    local total, missing = 0, {}
    local list = (kind == 'dump') and ORDER or { kind }
    if kind ~= 'dump' and kinds[kind] == nil then
        emit('done', seq, { 'kind', kind, 'lines', 0, 'error', 'unknown-kind' })
        return
    end
    for _, k in ipairs(list) do
        local n, miss = runKind(k, seq)
        total = total + n
        if miss then missing[#missing + 1] = miss end
    end
    emit('done', seq, { 'kind', kind, 'lines', total,
                        'missing', #missing > 0 and table.concat(missing, ',') or nil })
end

-- ---------------------------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------------------------
local started = false
local lastBeat = 0
local lastCellKey = nil
local lastInvCheck = 0
local lastInvKey = nil

local function cellKey()
    return get(function() return tostring(self.cell.id) end) or ''
end
local function invKey()
    local counts, ids = inventoryCounts()
    local parts = {}
    for _, id in ipairs(ids) do parts[#parts + 1] = id .. ':' .. counts[id] end
    return table.concat(parts, ',')
end

local function onFrame()
    local now = core.getRealTime()
    if not started then
        -- The first frames run while the world is still loading (simulation time stays 0); the
        -- ready line waits for the simulation to run, so it marks a client that is in the world.
        if (get(core.getSimulationTime) or 0) <= 0 then return end
        started = true
        detectCaps()
        emit('ready', 0, { 'probe', 1, 'version', VERSION, 'caps', table.concat(capList, ','),
                           'period', conf.period, 'range', conf.range })
        lastBeat = now
        lastCellKey = cellKey()
        if caps.inv then lastInvKey = get(invKey) end
        lastInvCheck = now
        return
    end
    if caps.cell then
        local k = cellKey()
        if k ~= lastCellKey then
            lastCellKey = k
            runKind('cell', 0)
        end
    end
    if caps.inv and now - lastInvCheck >= 2 then
        lastInvCheck = now
        local k = get(invKey)
        if k ~= nil and k ~= lastInvKey then
            lastInvKey = k
            runKind('inv', 0)
        end
    end
    if now - lastBeat >= conf.period then
        lastBeat = now
        runKind('cell', 0)
        runKind('stats', 0)
    end
end

local function onConsoleCommand(mode, command)
    if mode ~= '' or type(command) ~= 'string' then return end
    local kind, seq = command:match('^%s*lua%s+rigprobe%s+([%w_]+)%s+(%d+)%s*$')
    if kind == nil then return end
    if not started then
        started = true
        detectCaps()
    end
    request(kind, tonumber(seq))
end

local function onQuestUpdate(questId, stage)
    if not caps.quest then return end
    local finished = get(function() return types.Player.quests(self)[questId].finished end)
    emit('quest', 0, { 'id', questId, 'stage', stage, 'finished', finished })
end

local function restart() started = false end

return {
    engineHandlers = {
        onFrame = onFrame,
        onConsoleCommand = onConsoleCommand,
        onQuestUpdate = onQuestUpdate,
        onInit = restart,
        onLoad = restart,
    },
}
