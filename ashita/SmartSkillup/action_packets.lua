-- Parsers for the incoming action (0x028) and action message (0x029) packets.
-- Offsets follow Windower packets/fields.lua, in bits from the start of the packet (header included).
-- Param sits at bit 86 and the first target at bit 150, which differs from the comments in fields.lua.
-- Only the first target and its first action are read, because that is all SmartSkillup uses.
-- Bit fields are read LSB-first within each byte (matches Windower's extract).

local M = {};

-- Reads n bits starting at bit position pos, least significant bit first.
local function read_bits(data, pos, n)
    local value = 0;
    for i = 0, n - 1 do
        local p = pos + i;
        local byte = string.byte(data, math.floor(p / 8) + 1);
        if not byte then return nil; end
        value = value + (math.floor(byte / 2 ^ (p % 8)) % 2) * 2 ^ i;
    end
    return value;
end

local ACTION_START_OFFSET = 36; -- from the start of a target entry: 32-bit id + 4-bit action count
local TARGET_START = 150;       -- bit position of the first target entry, after the 0x028 base fields

-- Returns { actor_id, category, param, targets = { [1] = { actions = { [1] = { param, message } } } } }.
function M.parse_action(data)
    local act = {
        actor_id = read_bits(data, 40, 32),
        target_count = read_bits(data, 72, 10),
        category = read_bits(data, 82, 4),
        param = read_bits(data, 86, 16),
        targets = {},
    };
    if not act.actor_id or not act.target_count or act.target_count == 0 then
        return act;
    end

    local target_pos = TARGET_START;
    local action_count = read_bits(data, target_pos + 32, 4);
    if action_count and action_count > 0 then
        local action_pos = target_pos + ACTION_START_OFFSET;
        -- Action base: Reaction 5, Animation 12, Effect 4, Stagger 3, Knockback 3, Param 17, Message 10, unknown 31.
        act.targets[1] = { actions = { {
            param = read_bits(data, action_pos + 27, 17),
            message = read_bits(data, action_pos + 50, 10),
        } } };
    end
    return act;
end

-- Returns { actor_id, target_id, param1, message } from an action message (0x029) packet.
function M.parse_action_message(data)
    return {
        actor_id = read_bits(data, 32, 32),
        target_id = read_bits(data, 64, 32),
        param1 = read_bits(data, 96, 32),
        message = read_bits(data, 192, 16),
    };
end

return M;
