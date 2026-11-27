addon.name    = 'SmartSkillup';
addon.author  = 'Roland-J';
addon.version = '0.1.0';
addon.desc    = 'Ashita port of SmartSkillup (in progress: shim and entry only).';
addon.link    = 'https://github.com/Roland-J/SmartSkillup';

require('common');

local shim = require('windower_shim');
local compat = require('sms_compat');
local last_job_check = 0;
local initialize_sms;
local check_job_change;

ashita.events.register('load', 'smartskillup_load', function()
    shim.install();
    compat.install_globals();
    require('statics');
    require('helpers');
    require('me');
    require('modules');
    require('sms_loop');
    windower.register_event('incoming chunk', function(id, data)
        if id == 0x062 then
            if not check_job_change() then process_skill_packet(data); end
        elseif id == 0x028 and me.id then
            process_action(require('action_packets').parse_action(data));
        elseif id == 0x029 and me.id then
            process_action_message(require('action_packets').parse_action_message(data));
        elseif S{0x032, 0x033, 0x034}:contains(id) then
            pause_event('NPC');
        elseif id == 0x05C then
            -- The NPC menu sends an unlock (0x052) before the player decides, so the first one is ignored.
            me.awaiting_0x052 = true;
            coroutine.schedule(function() me.awaiting_0x052 = nil; end, 1.5);
        elseif id == 0x052 then
            if me.awaiting_0x052 then
                me.awaiting_0x052 = nil;
            else
                unpause_event('NPC', 1.5);
            end
        elseif id == 0x00B then
            pause_event('Zoning');
        elseif id == 0x00A then
            unpause_event('Zoning', 6);
        end
    end);
    skill_data_request_timeout();

    ashita.events.register('d3d_present', 'smartskillup_job_watch', function()
        local now = os.clock();
        if now - last_job_check < 0.5 then return; end
        last_job_check = now;
        check_job_change();
        check_status_change();
        check_zone_change();
    end);
    print('[SmartSkillup] Loaded (build ' .. require('sms_res').build .. '). Loop, modules (incl. food, moogle, T.Target), events, status pauses and auto-rest are ported. Use /sms add <skill>, /sms togm <module>, /sms go, /sms stop.');
end);

ashita.events.register('unload', 'smartskillup_unload', function()
    shim.uninstall();
end);

ashita.events.register('d3d_present', 'smartskillup_compat_tick', function()
    compat.tick();
end);

-- Calls each shim function and prints the result, so the Ashita lookups can be checked in game.
local function run_self_test()
    print('[SmartSkillup][TEST] build: ' .. require('sms_res').build);
    local function check(label, fn)
        local ok, result = pcall(fn);
        if not ok then
            print('[SmartSkillup][TEST] FAIL ' .. label .. ': ' .. tostring(result));
        elseif type(result) == 'table' then
            local count = 0;
            for _ in pairs(result) do count = count + 1; end
            local detail = '';
            if result.name then detail = ' name=' .. tostring(result.name) .. ' index=' .. tostring(result.index); end
            print('[SmartSkillup][TEST] OK   ' .. label .. ' (table, ' .. count .. ' entries' .. detail .. ')');
        else
            print('[SmartSkillup][TEST] OK   ' .. label .. ' = ' .. tostring(result));
        end
        return result;
    end

    local player = check('get_player', function() return windower.ffxi.get_player(); end);
    if player then
        check('  name', function() return player.name; end);
        check('  main_job', function() return player.main_job .. ' ' .. tostring(player.main_job_level); end);
        check('  sub_job', function() return tostring(player.sub_job) .. ' ' .. tostring(player.sub_job_level); end);
        check('  hp/mp', function() return player.hp .. '/' .. player.mp; end);
    end
    check('get_party', function() return windower.ffxi.get_party(); end);
    local p = windower.ffxi.get_party() or {};
    print('[SmartSkillup][TEST] party1_count=' .. tostring(p.party1_count) .. ' party2_count=' .. tostring(p.party2_count) .. ' party3_count=' .. tostring(p.party3_count) .. ' party1_leader=' .. tostring(p.party1_leader) .. ' my_id=' .. tostring(me and me.id));
    for i = 0, 5 do
        local m = p['p' .. i];
        if m then print('[SmartSkillup][TEST]   p' .. i .. ' name=' .. tostring(m.name) .. ' spawn_type=' .. tostring(m.mob and m.mob.spawn_type)); end
    end
    if me then
        update_me_party();
        print('[SmartSkillup][TEST] can_summon_trusts=' .. tostring(me.can_summon_trusts) .. ' has_trust_target=' .. tostring(me.has_trust_target));
    end
    check('get_info', function() return windower.ffxi.get_info(); end);
    check('get_spell_recasts', function() return windower.ffxi.get_spell_recasts(); end);
    check('get_ability_recasts', function() return windower.ffxi.get_ability_recasts(); end);
    check('get_mob_by_target t', function() return windower.ffxi.get_mob_by_target('t'); end);
    check('get_mob_by_target bt', function() return windower.ffxi.get_mob_by_target('bt'); end);
    check('get_mob_by_target pet', function() return windower.ffxi.get_mob_by_target('pet'); end);
    check('get_mob_by_target p1', function() return windower.ffxi.get_mob_by_target('p1'); end);

    -- Probes the spell resource fields the data layer will depend on.
    local res = AshitaCore:GetResourceManager();
    local function probe(label, spell)
        if not spell then
            print('[SmartSkillup][TEST] ' .. label .. ' = nil');
            return;
        end
        print('[SmartSkillup][TEST] ' .. label .. ': Id=' .. tostring(spell.Id)
            .. ' Index=' .. tostring(spell.Index)
            .. ' ManaCost=' .. tostring(spell.ManaCost)
            .. ' RecastDelay=' .. tostring(spell.RecastDelay)
            .. ' Skill=' .. tostring(spell.Skill));
        for i = 1, 4 do
            print('[SmartSkillup][TEST]   Name[' .. i .. '] = ' .. tostring(spell.Name and spell.Name[i]));
        end
    end
    probe('GetSpellById(1)', res:GetSpellById(1));
    probe('GetSpellByName("Cure", 0)', res:GetSpellByName('Cure', 0));

    local sms_res = require('sms_res');
    check('sms_res.spell_by_name Cure', function()
        local s = sms_res.spell_by_name('Cure');
        return s and ('id=' .. s.id .. ' en=' .. s.en .. ' mp=' .. s.mp_cost .. ' recast=' .. s.recast_delay .. ' skill=' .. s.skill_id) or 'nil';
    end);
    check('sms_res.spell_by_name NotASpell', function() return tostring(sms_res.spell_by_name('NotASpell')); end);

    check('T contains/find', function()
        local t = T{ 'a', 'b' };
        return tostring(t:contains('b')) .. ' ' .. tostring(t:find('b'));
    end);
    check('S contains', function()
        local s = S{ 'BLU' };
        return tostring(s:contains('BLU')) .. ' ' .. tostring(s:contains('RDM'));
    end);
    check('wmatch', function()
        return tostring(('Cure'):wmatch('cure*|raise')) .. ' ' .. tostring(('Refresh'):wmatch('cure*|raise'));
    end);
    local queued_at = os.clock();
    local queued = compat.schedule(function()
        print('[SmartSkillup][TEST] OK   scheduled task fired after ' .. string.format('%.2f', os.clock() - queued_at) .. 's');
    end, 1);
    check('schedule queued', function()
        return 'queued at clock=' .. string.format('%.2f', queued_at) .. ', pending=' .. compat.pending_count() .. ' (expect a fired line in ~1s)';
    end);
    -- Item lookups and container scan (container slots are 1-based; Id == 0 or Count == 0 means empty).
    local food_names = { 'B.E.W. Pitaru', 'Seafood Pitaru', 'Poultry Pitaru', 'Stuffed Pitaru' };
    local food_ids = {};
    for _, name in ipairs(food_names) do
        local id = sms_res.item_id_by_name(name);
        food_ids[id or -1] = name;
        print('[SmartSkillup][TEST] item ' .. name .. ' = ' .. tostring(id));
    end
    local inventory = AshitaCore:GetMemoryManager():GetInventory();
    for _, bag in ipairs({ 0, 5, 6, 7 }) do
        local max = inventory:GetContainerCountMax(bag);
        local used, foods = 0, {};
        for slot = 1, max do
            local item = inventory:GetContainerItem(bag, slot);
            if item and item.Id ~= 0 and item.Count ~= 0 then
                used = used + 1;
                if food_ids[item.Id] then
                    table.insert(foods, food_ids[item.Id] .. ' x' .. item.Count .. ' (slot ' .. slot .. ')');
                end
            end
        end
        print('[SmartSkillup][TEST] bag ' .. bag .. ': max=' .. tostring(max) .. ' used=' .. used
            .. (#foods > 0 and (' food: ' .. table.concat(foods, ', ')) or ''));
    end

    -- Spell pipeline: statics, helpers, and me, then the data build from the Ashita resource manager.
    check('require statics/helpers/me', function()
        require('statics');
        require('helpers');
        require('me');
        return 'ok';
    end);
    check('sms_res.skill_name(33)', function() return sms_res.skill_name(33); end);
    check('sms_res.all_spells count', function()
        local spells = sms_res.all_spells();
        local n = 0;
        for _ in ipairs(spells) do n = n + 1; end
        return n;
    end);
    check('Cure levels (expect WHM=1, raw index 4)', function()
        local raw = AshitaCore:GetResourceManager():GetSpellByName('Cure', 0);
        local lv = {};
        for job = 0, 3 do
            table.insert(lv, job .. ':' .. tostring(raw and raw.LevelRequired[job + 1]));
        end
        local parsed = nil;
        for _, s in ipairs(sms_res.all_spells()) do
            if s.en == 'Cure' then parsed = s.levels[3]; break; end
        end
        return table.concat(lv, ' ') .. ' | parsed levels[3]=' .. tostring(parsed);
    end);
    check('zone + in_town', function()
        if not me then build_me_table(); end
        update_me_zone();
        return 'zone=' .. tostring(me.zone) .. ' name=' .. tostring(me.zone_name) .. ' in_town=' .. tostring(me.in_town);
    end);
    check('build_me_table + get_main_skills + get_valid_spells', function()
        build_me_table();
        get_main_skills();
        get_valid_spells();
        local skills = 0;
        for _ in pairs(main_skills) do skills = skills + 1; end
        local known = 0;
        for _ in pairs(known_spells) do known = known + 1; end
        return 'main_job=' .. tostring(me.main_job) .. ' skills=' .. skills .. ' known=' .. known;
    end);
    check('valid_spells_sorted counts', function()
        local parts = {};
        for skill, spells in pairs(valid_spells_sorted or {}) do
            table.insert(parts, skill .. '=' .. #spells);
        end
        table.sort(parts);
        return table.concat(parts, ', ');
    end);
    check('Summoning candidates (levels[main], known, ignore reason)', function()
        local out = {};
        for _, s in ipairs(sms_res.all_spells()) do
            if s.skill == 38 and s.levels[me.main_job_id] then
                local reason = 'accepted';
                for _, ig in pairs(ignored_spells['Summoning Magic'] or {}) do
                    if ig.id == s.id then reason = ig.reason; end
                end
                table.insert(out, s.en .. '(' .. s.levels[me.main_job_id] .. ', known=' .. tostring(known_spells[s.id] or false) .. ', ' .. reason .. ')');
            end
        end
        return #out .. ' spells: ' .. table.concat(out, '; ');
    end);
    check('known spell names (from get_spells)', function()
        local names = {};
        for _, s in ipairs(sms_res.all_spells()) do
            if known_spells[s.id] then table.insert(names, s.id .. ':' .. s.en); end
        end
        return #names .. ' known: ' .. table.concat(names, ', ');
    end);
    check('HasSpell diagnostic (by name)', function()
        local player = AshitaCore:GetMemoryManager():GetPlayer();
        local parts = {};
        for _, name in ipairs({ 'Cure', 'Cure II', 'Dia', 'Paralyze', 'Poison', 'Stone', 'Carbuncle', 'Fire Spirit', 'Stone VI' }) do
            local s = sms_res.spell_by_name(name);
            if s then
                table.insert(parts, name .. '[' .. s.id .. ']=' .. tostring(player:HasSpell(s.id)));
            else
                table.insert(parts, name .. '=no-resource');
            end
        end
        return table.concat(parts, ', ');
    end);
    check('HasSpell repeat + HasSpellData probe', function()
        local player = AshitaCore:GetMemoryManager():GetPlayer();
        local parts = {};
        for _, id in ipairs({ 1, 2, 179, 215, 220 }) do
            local runs = {};
            for i = 1, 3 do table.insert(runs, tostring(player:HasSpell(id))); end
            local ok, data = pcall(function() return player:HasSpellData(id); end);
            table.insert(parts, id .. ' HasSpell=[' .. table.concat(runs, ',') .. '] HasSpellData=' .. (ok and tostring(data) or ('err: ' .. tostring(data))));
        end
        return table.concat(parts, ' | ');
    end);
    check('resource names for suspect ids', function()
        local rm = AshitaCore:GetResourceManager();
        local player = AshitaCore:GetMemoryManager():GetPlayer();
        local parts = {};
        for _, id in ipairs({ 2, 23, 24, 56, 147, 159, 179, 215 }) do
            local r = rm:GetSpellById(id);
            local name = (r and r.Name and r.Name[1]) or 'nil';
            table.insert(parts, id .. '=' .. name .. '(known=' .. tostring(player:HasSpell(id)) .. ')');
        end
        local dia = sms_res.spell_by_name('Dia');
        local stone = sms_res.spell_by_name('Stone');
        table.insert(parts, 'spell_by_name Dia->' .. tostring(dia and dia.id) .. ' Stone->' .. tostring(stone and stone.id));
        return table.concat(parts, ' | ');
    end);

    -- Step 2 probes: buffs, status, and target entity fields used by the module logic.
    check('get_buffs (shim)', function()
        local ids = windower.ffxi.get_buffs();
        return #ids .. ' buffs: ' .. table.concat(ids, ',');
    end);
    check('raw GetBuffs slots 0-31 (expect -1 for empty)', function()
        local buffs = AshitaCore:GetMemoryManager():GetPlayer():GetBuffs();
        local parts = {};
        for i = 1, 32 do table.insert(parts, tostring(buffs[i])); end
        return table.concat(parts, ',');
    end);
    check('get_status (shim) vs entity Status', function()
        local ent = GetPlayerEntity();
        return 'shim=' .. tostring(windower.ffxi.get_status()) .. ' entity=' .. tostring(ent and ent.Status);
    end);
    check('job ability lookups (id, recast_id, current recast)', function()
        local sms_res = require('sms_res');
        local recasts = windower.ffxi.get_ability_recasts();
        local parts = {};
        for _, name in ipairs({ 'Convert', 'Composure', 'Sublimation', 'Radial Arcana', 'Full Circle' }) do
            local ab = sms_res.ability_by_name(name);
            if ab then
                table.insert(parts, name .. '=id ' .. ab.id .. '/recast ' .. tostring(ab.recast_id) .. '/now ' .. tostring(recasts[ab.recast_id]));
            else
                table.insert(parts, name .. '=nil');
            end
        end
        return table.concat(parts, ' | ');
    end);
    check('target entity Distance/SpawnFlags (set a target first)', function()
        local t = AshitaCore:GetMemoryManager():GetTarget():GetTargetIndex(0);
        t = t ~= 0 and GetEntity(t) or nil;
        if not t then return 'no target'; end
        local sqrt_dist = math.sqrt(t.Distance);
        return t.Name .. ' Distance=' .. tostring(t.Distance) .. ' (sqrt=' .. string.format('%.1f', sqrt_dist)
            .. ') SpawnFlags=0x' .. string.format('%X', t.SpawnFlags) .. ' spawn_type=' .. tostring(windower.ffxi.get_mob_by_target('t').spawn_type);
    end);
end

-- Builds the session data the loop needs (same order as the self test).
local function prepare_session()
    build_me_table();
    get_main_skills();
    get_valid_spells();
    determine_modules();
end

-- Prepares the session data and modules on first use. /sms test fills the spell lists without the modules, so both are checked.
local function ensure_session()
    if next(valid_spells_sorted) == nil or modules.refresh == nil then prepare_session(); end
end

-- Detects a main or sub job change and schedules the reset. Returns true when a job change was found.
-- Windower sets awaiting_initialize until its delayed reset runs, so false-flag cap events from the server are ignored.
function check_job_change()
    local p = windower.ffxi.get_player();
    if not p or me.main_job_id == nil then return false; end
    -- Job memory is cleared or reloading while zoning, so ignore it until the zone pause ends.
    if not p.main_job_id or p.main_job_id == 0 or event_pauses.Zoning then return false; end
    if p.main_job_id == me.main_job_id and p.sub_job_id == me.sub_job_id then
        update_me_job();
        return false;
    end
    update_me_job();
    me.awaiting_initialize = true;
    coroutine.schedule(initialize_sms, 0.5);
    return true;
end

-- Resets the session and rebuilds the job data after a job change (Windower's initialize_sms).
function initialize_sms()
    active, paused, going, skill_data_retrieved, skill_to_skillup, skills_to_skillup = false, false, false, false, nil, T{};
    end_timeout_and_decision('job change');
    prepare_session();
    skill_data_request_timeout();
    me.awaiting_initialize = nil;
end

-- Adds a skill by partial name. Waits for the skill packet when the cap status is not known yet (Windower's 'add' flow).
local function sms_add(term, attempts)
    attempts = attempts or 0;
    if next(valid_spells_sorted) == nil then prepare_session(); end
    local match = nil;
    for skill_en in pairs(main_skills) do
        if skill_en:lower():find(term:lower(), 1, true) then match = skill_en; end
    end
    if not match then
        return print('[SmartSkillup] No main skill matches "' .. term .. '".');
    elseif main_skills[match].capped == nil then
        if attempts >= 5 then
            return print('[SmartSkillup] Failed to retrieve skill cap status, please try again.');
        end
        print('[SmartSkillup] [WAIT] Please wait, fetching skill cap status...');
        request_skill_data();
        return coroutine.schedule(function() sms_add(term, attempts + 1); end, 2);
    elseif main_skills[match].capped then
        return print('[SmartSkillup] [DENIED] ' .. match .. ' is currently capped (' .. main_skills[match].level .. ').');
    elseif not valid_spells_sorted[match] or #valid_spells_sorted[match] == 0 then
        return print('[SmartSkillup] "' .. match .. '" has no valid spells for this job.');
    elseif skills_to_skillup:contains(match) then
        return print('[SmartSkillup] "' .. match .. '" is already in the session.');
    end
    skills_to_skillup:insert(match);
    if skill_to_skillup == nil then skill_to_skillup = match; end
    print('[SmartSkillup] Added "' .. match .. '" (level ' .. main_skills[match].level .. '). Session skills: ' .. table.concat(skills_to_skillup, ', '));
end

-- Handles /sms mplimit [silent] [toggle | <number>] (Windower's mplimit command).
local function handle_mplimit(args)
    local tokens = {};
    local silent = false;
    for word in args:gmatch('%S+') do
        if word == 'silent' then silent = true; else table.insert(tokens, word); end
    end
    local action = tokens[1];
    if action == nil then
        return print('[SmartSkillup] MP Limit is ' .. tostring(mp_limit));
    elseif action == 'toggle' then
        toggle_mp_limit();
    elseif tonumber(action) then
        set_mp_limit(tonumber(action));
    else
        return print('[SmartSkillup] Usage: /sms mplimit [silent] [toggle | <number>].');
    end
    if not silent then print('[SmartSkillup] Set MP Limit to ' .. tostring(mp_limit)); end
end

-- Returns true when the command was one of ours, so the caller can block it.
local function dispatch(cmd)
    if cmd:match('^/smartskillup%s+test%s*$') or cmd:match('^/sms%s+test%s*$') then
        run_self_test();
    elseif cmd:match('^/sms%s+go%s*$') or cmd:match('^/smartskillup%s+go%s*$') or cmd:match('^/sms%s+go%s+".*"%s*$') or cmd:match('^/smartskillup%s+go%s+".*"%s*$') then
        ensure_session();
        begin_loop('command');
    elseif cmd:match('^/sms%s+stop%s*$') or cmd:match('^/smartskillup%s+stop%s*$') then
        active, going, paused = false, false, false;
        end_timeout_and_decision('command stop');
        print('[SmartSkillup] Stopped.');
    elseif cmd:match('^/sms%s+debug%s*%S*%s*$') or cmd:match('^/smartskillup%s+debug%s*%S*%s*$') then
        local mode = (cmd:match('^/%S+%s+debug%s+(%S+)') or 'norm'):lower();
        if debugModes[mode] == nil then
            print('[SmartSkillup] No "' .. mode .. '" debug mode exists. Use "norm" or "deep".');
        else
            debugModes[mode] = not debugModes[mode];
            print('[SmartSkillup] Debug mode "' .. mode .. '" is now ' .. (debugModes[mode] and 'ON' or 'OFF') .. '.');
        end
    elseif cmd:match('^/sms%s+add%s+%S') or cmd:match('^/smartskillup%s+add%s+%S') then
        sms_add(cmd:match('^/%S+%s+add%s+(.-)%s*$'));
    elseif cmd:match('^/%S+%s+mplimit$') or cmd:match('^/%S+%s+mplimit%s') then
        handle_mplimit(cmd:match('^/%S+%s+mplimit%s*(.-)%s*$'));
    elseif cmd:match('^/sms%s+togm%s+%S') or cmd:match('^/smartskillup%s+togm%s+%S') then
        ensure_session();
        toggle_module(cmd:match('^/%S+%s+togm%s+(%S+)%s*$'):lower());
    else
        return false;
    end
    return true;
end

shim.set_self_command_handler(function(cmd)
    dispatch('/' .. cmd);
end);

ashita.events.register('command', 'smartskillup_command', function(e)
    if dispatch(e.command or '') then e.blocked = true; end
end);

