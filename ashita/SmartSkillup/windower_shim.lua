-- Maps the subset of the Windower API used by SmartSkillup onto Ashita v4.
-- Calls marked UNVERIFIED use Ashita names not yet confirmed against the SDK annotations.

local shim = {}

local timers = {}
local self_command_handler = nil
local unmapped_events = {}

local function now()
    return os.clock()
end

local function log(msg)
    print('[SmartSkillup] ' .. tostring(msg))
end

-- Windower-style 'input /ma "Cure" <me>' -> Ashita chat command '/ma "Cure" <me>'
local function send_command(cmd)
    if type(cmd) ~= 'string' or cmd == '' then return end

    local delay, rest = cmd:match('^wait%s+([%d%.]+);%s*(.+)$')
    if delay then
        table.insert(timers, { at = now() + tonumber(delay), cmd = rest })
        return
    end

    local input = cmd:match('^input%s+(.+)$')
    if input then
        if input:sub(1, 1) ~= '/' then input = '/' .. input end
        AshitaCore:GetChatManager():QueueCommand(1, input)
        return
    end

    if cmd:match('^sms%s') or cmd:match('^skillup%s') then
        if self_command_handler then self_command_handler(cmd) end
        return
    end

    log('Unsupported command in shim: ' .. cmd)
end

-- d3d_present is the frame tick, so delayed commands run on the main thread.
local function tick()
    if #timers == 0 then return end
    local t = now()
    for i = #timers, 1, -1 do
        if timers[i].at <= t then
            local cmd = timers[i].cmd
            table.remove(timers, i)
            send_command(cmd)
        end
    end
end

-- Windower spawn_type values used by the loop: 16 = monster, 14 = trust (NPC in the party).
local function spawn_type_from_flags(flags)
    flags = flags or 0;
    if bit.band(flags, 0x10) ~= 0 then return 16; end
    if bit.band(flags, 0x06) == 0x06 then return 14; end
    return 0;
end

local function entity_to_mob(index)
    if not index or index == 0 then return nil end
    local ent = GetEntity(index)
    if not ent or ent.Name == nil or ent.Name == '' then return nil end
    return {
        id = ent.ServerId,
        index = index,
        name = ent.Name,
        hpp = ent.HPPercent,
        distance = ent.Distance,
        spawn_type = spawn_type_from_flags(ent.SpawnFlags),
    }
end

local function get_player()
    local mm = AshitaCore:GetMemoryManager()
    local player = mm:GetPlayer()
    local party = mm:GetParty()
    if not player or not party then return nil end

    local res = AshitaCore:GetResourceManager()
    local main_job = player:GetMainJob()
    local sub_job = player:GetSubJob()
    return {
        name = party:GetMemberName(0),
        id = party:GetMemberServerId(0),
        hp = party:GetMemberHP(0),
        mp = party:GetMemberMP(0),
        hpp = party:GetMemberHPPercent(0),
        mpp = party:GetMemberMPPercent(0),
        tp = party:GetMemberTP(0),
        main_job_id = main_job,
        main_job = res:GetString('jobs.names_abbr', main_job),
        main_job_level = player:GetMainJobLevel(),
        sub_job_id = sub_job,
        sub_job = res:GetString('jobs.names_abbr', sub_job),
        sub_job_level = player:GetSubJobLevel(),
    }
end

-- Known spells keyed by spell id, like Windower's get_spells(). Uses IPlayer:HasSpell (SDK-verified).
local function get_spells()
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    local out = {}
    if not player then return out end
    for id = 0, 1023 do
        if player:HasSpell(id) then out[id] = true end
    end
    return out
end

local function get_spell_recasts()
    local mm = AshitaCore:GetMemoryManager()
    local recast = mm.GetRecast and mm:GetRecast() or nil
    local out = {}
    if not recast then return out end
    for id = 0, 1023 do
        local timer = recast:GetSpellTimer(id)
        if timer and timer > 0 then out[id] = timer end
    end
    return out
end

local function get_ability_recasts()
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    local out = {}
    if not player then return out end
    -- Ashita indexes by timer slot; Windower indexes by recast_id. Map before use.
    for index = 0, 31 do
        out[index] = player:GetAbilityRecast(index)
    end
    return out
end

-- Active buff ids. IPlayer:GetBuffs() returns an int16 array; empty slots hold -1.
local function get_buffs()
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    local out = {}
    if not player then return out end
    local buffs = player:GetBuffs()
    -- GetBuffs() is 1-based from Lua: slot 0 is nil, slots 1-32 hold buff ids, empty slots are -1.
    for i = 1, 32 do
        local id = buffs[i]
        if id and id > 0 then out[#out + 1] = id end
    end
    return out
end

-- Player status code (0 idle, 1 engaged, 33 resting), matching Windower's get_player().status.
local function get_status()
    local player = GetPlayerEntity()
    return player and player.Status or 0
end

local function get_mob_by_target(target)
    if target == 't' then
        local index = AshitaCore:GetMemoryManager():GetTarget():GetTargetIndex(0)
        return entity_to_mob(index)
    end
    local slot = target and target:match('^p(%d)$')
    if slot then
        local party = AshitaCore:GetMemoryManager():GetParty()
        return party and entity_to_mob(party:GetMemberTargetIndex(tonumber(slot))) or nil
    end
    return nil
end

local function get_info()
    local party = AshitaCore:GetMemoryManager():GetParty()
    return { zone = party and party:GetMemberZone(0) or nil }
end

local function get_party()
    local party = AshitaCore:GetMemoryManager():GetParty()
    local members = {}
    if not party then return members end
    for i = 0, 17 do
        if party:GetMemberIsActive(i) == 1 then
            members[#members + 1] = {
                name = party:GetMemberName(i),
                id = party:GetMemberServerId(i),
                hp = party:GetMemberHP(i),
                mp = party:GetMemberMP(i),
                main_job_id = party:GetMemberMainJob(i),
                main_job_level = party:GetMemberMainJobLevel(i),
            }
        end
    end
    return members
end

-- Bag contents keyed like Windower's get_items(). UNVERIFIED: enabled_* flags are always true,
-- since Ashita has no equivalent of Windower's per-bag enable toggle.
local bag_keys = { [0] = 'inventory', [5] = 'satchel', [6] = 'sack', [7] = 'case' }

local function get_items()
    local inv = AshitaCore:GetMemoryManager():GetInventory()
    local out = {}
    if not inv then return out end
    for container, key in pairs(bag_keys) do
        local bag = {}
        for slot = 1, inv:GetContainerCountMax(container) do
            local item = inv:GetContainerItem(container, slot)
            if item and item.Id ~= 0 and item.Count ~= 0 then
                bag[slot] = { id = item.Id, count = item.Count }
            end
        end
        out[key] = bag
        out['enabled_' .. key] = true
    end
    out.max_inventory = inv:GetContainerCountMax(0)
    out.count_inventory = 0
    for _ in pairs(out.inventory) do out.count_inventory = out.count_inventory + 1 end
    return out
end

local event_map = {
    ['outgoing chunk'] = 'packet_out',
    ['incoming chunk'] = 'packet_in',
    ['addon command'] = 'command',
}

local function register_event(...)
    local args = { ... }
    local fn = args[#args]
    for i = 1, #args - 1 do
        local name = args[i]
        local ash = event_map[name]
        if ash then
            ashita.events.register(ash, 'smartskillup_' .. ash, function(e)
                if ash == 'command' then
                    fn(e.command)
                elseif ash == 'packet_in' or ash == 'packet_out' then
                    fn(e.id, e.data)
                end
            end)
        elseif not unmapped_events[name] then
            unmapped_events[name] = true
            log('Event not yet mapped in shim: ' .. name)
        end
    end
end

function shim.install()
    windower = windower or {}
    windower.send_command = send_command
    windower.add_to_chat = function(_, msg) log(msg) end
    windower.convert_auto_trans = function(s) return s end
    windower.register_event = register_event
    windower.ffxi = {
        get_player = get_player,
        get_party = get_party,
        get_items = get_items,
        get_info = get_info,
        get_spells = get_spells,
        get_spell_recasts = get_spell_recasts,
        get_ability_recasts = get_ability_recasts,
        get_buffs = get_buffs,
        get_status = get_status,
        get_mob_by_index = entity_to_mob,
        get_mob_by_target = get_mob_by_target,
    }
    ashita.events.register('d3d_present', 'smartskillup_tick', tick)
end

function shim.set_self_command_handler(fn)
    self_command_handler = fn
end

-- UNVERIFIED: ashita.events.unregister
function shim.uninstall()
    timers = {}
    ashita.events.unregister('d3d_present', 'smartskillup_tick')
end

return shim
