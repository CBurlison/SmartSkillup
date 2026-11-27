-- Ported from the Windower SmartSkillup.lua/helpers.lua module logic (determine_modules, use_module, update_best_cures).
-- Ported modules: Convert (with HP recovery), Composure, Refresh, Haste, Sublimation.
-- Not ported yet: Food, Moogle, T.Target, Geo-Refresh, Radial Arcana (they are never available).

local sms_res = require('sms_res');

modules = modules or {};

local spell_index = nil;
-- Finds a spell by its exact English name from the resource manager, shaped for is_valid().
local function find_spell(name)
    if not spell_index then
        spell_index = {};
        for _, spell in ipairs(sms_res.all_spells()) do
            spell_index[spell.en] = spell;
        end
    end
    return spell_index[name];
end

-- Returns the first name in priority order that the player can use, or nil.
local function best_valid_spell(names)
    for _, name in ipairs(names) do
        local spell = find_spell(name);
        if spell and is_valid(spell, sms_res.skill_name(spell.skill), true) then
            return spell;
        end
    end
    return nil;
end

local function has_job(job, level)
    return (me.main_job == job and me.main_job_level >= level) or (me.sub_job == job and me.sub_job_level >= level);
end

-- Stores the player's current buff ids in buffidactive (the table is reused, so other code keeps its reference).
function update_me_buffs()
    for id in pairs(buffidactive) do buffidactive[id] = nil; end
    for _, id in ipairs(windower.ffxi.get_buffs()) do buffidactive[id] = true; end
end

-- Builds the two best cures the main job can cast, used for recovery after convert.
function update_best_cures()
    me.best_cures = {};
    me.best_cure_index = nil;
    for i = 6, 1, -1 do
        local cure = find_spell('Cure' .. numerals[i]);
        if cure and is_valid(cure, sms_res.skill_name(cure.skill), true) then
            if me.best_cures[1] == nil then
                me.best_cures[1] = { en = cure.en, mp_cost = cure.mp_cost };
                me.best_cure_index = 1;
            else
                me.best_cures[2] = { en = cure.en, mp_cost = cure.mp_cost };
                break;
            end
        end
    end
end

-- Job-ability readiness: checks the recast now, and reschedules itself for when the recast ends.
function schedule_module_readiness(mod, immediate)
    if not immediate then return schedule_module_readiness:schedule(2, mod, true); end

    local recast = windower.ffxi.get_ability_recasts()[mod.res.recast_id] or 0;
    if recast == 0 then
        mod.ready = true;
    else
        mod.ready = false;
        schedule_module_readiness:schedule(recast + 0.1, mod, true);
    end
end

-- Composure is applied while Refresh or Haste is active but not yet on the player.
function evaluate_composure_active()
    local refresh, haste = modules.refresh, modules.haste;
    modules.compo.active = ((refresh.active and not buffidactive[buff_ids.refresh])
        or (haste.active and not buffidactive[buff_ids.haste])) and true or false;
end

-- Works out which modules this job can use, keeping the active flags the user has already set.
function determine_modules()
    known_spells = windower.ffxi.get_spells();

    local was_active = {};
    for key, mod in pairs(modules) do was_active[key] = mod.active; end

    local function new_module(key, label, res, kind)
        return {
            key = key, label = label, res = res, kind = kind,
            available = false, active = was_active[key] or false, ready = false, recovering = nil,
        };
    end

    local refresh_spell = best_valid_spell({ 'Battery Charge', 'Refresh III', 'Refresh II', 'Refresh' });
    local haste_spell = best_valid_spell({ 'Erratic Flutter', 'Haste II', 'Haste' });

    modules = {
        refresh = new_module('refresh', 'Refresh', refresh_spell, 'ma'),
        haste = new_module('haste', 'Haste', haste_spell, 'ma'),
        convert = new_module('convert', 'Convert', sms_res.ability_by_name('Convert'), 'ja'),
        compo = new_module('compo', 'Compos.', sms_res.ability_by_name('Composure'), 'ja'),
        sublim = new_module('sublim', 'Sublim.', sms_res.ability_by_name('Sublimation'), 'ja'),
    };

    modules.refresh.available = refresh_spell ~= nil;
    modules.haste.available = haste_spell ~= nil;
    modules.convert.available = has_job('RDM', 40) and modules.convert.res ~= nil;
    modules.compo.available = me.main_job == 'RDM' and me.main_job_level >= 50 and modules.compo.res ~= nil;
    modules.sublim.available = has_job('SCH', 35) and modules.sublim.res ~= nil;

    if modules.convert.available then
        update_best_cures();
        schedule_module_readiness(modules.convert, true);
    end
    if modules.compo.available then
        schedule_module_readiness(modules.compo, true);
        evaluate_composure_active();
    end
    if modules.sublim.available then
        schedule_module_readiness(modules.sublim, true);
    end
end

-- Handles /sms togm <module>, with the Windower rules for mutually exclusive modules.
function toggle_module(key)
    local mod = modules[key];
    if not mod or key == 'compo' then
        return print('[SmartSkillup] Unknown module "' .. tostring(key) .. '". Modules: convert, refresh, haste, sublim.');
    elseif not mod.available then
        return print('[SmartSkillup] Module "' .. mod.label .. '" is not available for your jobs.');
    end

    local adding = not mod.active;
    if key == 'convert' and adding then
        update_best_cures();
        if me.best_cures[1] == nil then
            return print('[SmartSkillup] No cure spells available for convert recovery.');
        end
    elseif adding and key == 'refresh' and modules.sublim.available then
        modules.sublim.active = false;
    elseif adding and key == 'sublim' and modules.refresh.available then
        modules.refresh.active = false;
    end

    mod.active = adding;
    if key == 'refresh' or key == 'haste' then
        evaluate_composure_active();
    end
    print('[SmartSkillup] ' .. (adding and 'Activated' or 'Deactivated') .. ' the "' .. mod.label .. '" module.');
end

-- TODO(ashita): the cancel command is unverified in Ashita (Windower used 'cancel <buff>').
local function cancel_buff(name)
    windower.send_command('input /cancel "' .. name .. '"');
end

-- Casts a spell or job ability on the player. Returns true when a command was sent.
local function use_on_self(mod)
    windower.send_command('input /' .. mod.kind .. ' "' .. mod.res.en .. '" <me>');
    return true;
end

-- Returns true when a module action was started, which pauses the decision loop.
function use_module()
    update_me_buffs();
    evaluate_composure_active();
    local convert, compo, refresh, haste, sublim = modules.convert, modules.compo, modules.refresh, modules.haste, modules.sublim;
    local resting = windower.ffxi.get_status() == RESTING_STATUS;

    -- CONVERT MODULE
    if convert.active and not me.JA_locked and me.mpp < 25 and me.mp > 0 and convert.ready then
        logger(chat_colors.grey, '[CONVERT MODULE] Using "' .. convert.res.en .. '"...');
        use_on_self(convert);
        schedule_module_readiness(convert);
        convert.recovering = true;
        return true;

    -- CONVERT HP RECOVERY MODULE
    elseif convert.recovering then
        local cure = me.best_cures[me.best_cure_index];
        if me.hpp > 80 then
            convert.recovering = nil;
            return false;
        elseif not cure or me.mp < cure.mp_cost then
            convert.recovering = nil;
            logger(chat_colors.yellow, '[CONVERT RECOVERY ISSUE] Not enough MP to recover.');
            return false;
        end
        local other = me.best_cure_index == 1 and 2 or 1;
        if me.best_cures[other] then me.best_cure_index = other; end
        windower.send_command('input /ma "' .. cure.en .. '" <me>');
        return true;

    -- COMPOSURE ON MODULE (before refresh/haste)
    elseif compo.active and not me.JA_locked and not buffidactive[buff_ids.composure] and compo.ready then
        logger(chat_colors.grey, '[AUTO MODULE] Temporarily applying "Composure"...');
        if refresh.active then cancel_buff('Refresh'); end
        if haste.active then cancel_buff('Haste'); end
        use_on_self(compo);
        schedule_module_readiness(compo);
        return true;

    -- REFRESH MODULE
    elseif refresh.active and not buffidactive[buff_ids.refresh] and me.mp >= refresh.res.mp_cost then
        logger(chat_colors.grey, '[REFRESH MODULE] Buffing self with "' .. refresh.res.en .. '"...');
        return use_on_self(refresh);

    -- HASTE MODULE
    elseif haste.active and not buffidactive[buff_ids.haste] and me.mp >= haste.res.mp_cost then
        logger(chat_colors.grey, '[HASTE MODULE] Buffing self with "' .. haste.res.en .. '"...');
        return use_on_self(haste);

    -- COMPOSURE OFF MODULE (after refresh/haste)
    elseif buffidactive[buff_ids.composure] then
        logger(chat_colors.grey, '[AUTO MODULE] Removing "Composure"...');
        cancel_buff('Composure');
        buffidactive[buff_ids.composure] = nil; -- accelerate the flag, the game removes it shortly after
        return use_module();

    -- SUBLIMATION MODULE
    elseif sublim.active and not resting then
        local activated = buffidactive[buff_ids.sublimation];
        local completed = buffidactive[buff_ids.sublimation + 1];
        if (not activated and not completed and me.mpp > 25 and sublim.ready)
        or (activated and me.mpp < 10)
        or (completed and me.mpp < 50 and sublim.ready) then
            use_on_self(sublim);
            schedule_module_readiness(sublim);
            return true;
        end
    end

    return false;
end
