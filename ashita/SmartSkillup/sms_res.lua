-- Spell data lookups backed by the Ashita resource manager.
-- Name[1] is the English name (verified in game); the language argument 0 is English.

local M = {};

-- Bump this when sms_res changes so /sms test shows which copy is loaded.
M.build = 'modules-v1';

-- Returns the item id for an English item name, or nil when the name is unknown.
function M.item_id_by_name(name)
    local item = AshitaCore:GetResourceManager():GetItemByName(name, 0);
    if not item or item.Id == nil then
        return nil;
    end
    return item.Id;
end

local spell_cache = nil;

-- Every named spell from the resource manager, shaped like Windower's res.spells entries:
-- { id, en, skill, levels = { [job_id] = level }, mp_cost, cast_time }.
-- LevelRequired is a 1-based Lua array, so job id j is read from index j + 1 (verified in game: Cure[0] is nil).
-- Ashita TargetFlags (plugins/sdk/ffxi/enums.h): Self 0x01, PartyMember 0x04, Enemy 0x20.
local function spell_targets(flags)
    flags = flags or 0;
    return {
        Self = bit.band(flags, 0x01) ~= 0,
        Party = bit.band(flags, 0x04) ~= 0,
        Enemy = bit.band(flags, 0x20) ~= 0,
    };
end

function M.all_spells()
    if spell_cache then
        return spell_cache;
    end
    local rm = AshitaCore:GetResourceManager();
    local out = {};
    for id = 0, 1023 do
        local spell = rm:GetSpellById(id);
        if spell and spell.Name and spell.Name[1] and spell.Name[1] ~= '' then
            local levels = {};
            for job = 0, 23 do
                local lvl = spell.LevelRequired and spell.LevelRequired[job + 1];
                if lvl and lvl > 0 then
                    levels[job] = lvl;
                end
            end
            table.insert(out, {
                id = id,
                en = spell.Name[1],
                skill = spell.Skill,
                type = spell.Type,
                levels = levels,
                mp_cost = spell.ManaCost,
                cast_time = spell.CastTime,
                targets = spell_targets(spell.Targets),
            });
        end
    end
    spell_cache = out;
    return out;
end

-- English names for the magic skill ids (FFXI skill ids, as used by Windower's res.skills).
-- The 'skills.names' resource key returned nil in game, so these are fixed here.
local magic_skill_names = {
    [33] = 'Healing Magic', [34] = 'Enhancing Magic', [35] = 'Enfeebling Magic', [36] = 'Elemental Magic',
    [37] = 'Dark Magic', [38] = 'Summoning Magic', [39] = 'Ninjutsu', [40] = 'Singing',
    [41] = 'Stringed Instrument', [42] = 'Wind Instrument', [43] = 'Blue Magic', [44] = 'Geomancy',
    [45] = 'Handbell',
};

-- Returns the English skill name for a magic skill id (for example 33 -> 'Healing Magic'), or nil.
function M.skill_name(skill_id)
    return magic_skill_names[skill_id];
end

-- GetSpellByName returned the wrong spell in game (Dia -> Blizzaga), so names are matched exactly over the resource table.
local spell_name_index = nil;
local function build_spell_name_index()
    local rm = AshitaCore:GetResourceManager();
    local index = {};
    for id = 0, 1023 do
        local spell = rm:GetSpellById(id);
        if spell and spell.Name and spell.Name[1] and spell.Name[1] ~= '' then
            index[spell.Name[1]:lower()] = id;
        end
    end
    return index;
end

-- Returns { id, en, recast_id, mp_cost, targets } for a job ability or weapon skill name, or nil when unknown.
-- recast_id is IAbility.RecastTimerId, the index used with get_ability_recasts().
function M.ability_by_name(name)
    local ability = AshitaCore:GetResourceManager():GetAbilityByName(name, 0);
    if not ability or ability.Id == nil or ability.Id == 0 then
        return nil;
    end
    return {
        id = ability.Id,
        en = ability.Name and ability.Name[1] or name,
        recast_id = ability.RecastTimerId,
        mp_cost = ability.ManaCost,
        targets = spell_targets(ability.Targets),
    };
end

-- Returns { id, en, mp_cost, recast_delay, skill_id } or nil when the name is unknown.
function M.spell_by_name(name)
    spell_name_index = spell_name_index or build_spell_name_index();
    local id = spell_name_index[name:lower()];
    if not id then
        return nil;
    end
    local spell = AshitaCore:GetResourceManager():GetSpellById(id);
    if not spell or not spell.Name then
        return nil;
    end
    return {
        id = id,
        en = spell.Name[1],
        mp_cost = spell.ManaCost,
        recast_delay = spell.RecastDelay,
        skill_id = spell.Skill,
    };
end

-- Returns { id, en, cast_time (seconds), skill } for a spell id, or nil. Ashita stores CastTime in quarter seconds.
function M.spell_by_id(id)
    local spell = AshitaCore:GetResourceManager():GetSpellById(id);
    if not spell or not spell.Name or not spell.Name[1] or spell.Name[1] == '' then
        return nil;
    end
    return {
        id = id,
        en = spell.Name[1],
        cast_time = spell.CastTime / 4.0,
        skill = spell.Skill,
    };
end

return M;
