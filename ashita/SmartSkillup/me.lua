-- Ported from the Windower me.lua (Copyright 2022, RolandJ, BSD 3-Clause; see the original in the repo root).
-- Vitals, job and food data come from polling the shim. Packet- and event-driven updates are TODO.

local compat = require('sms_compat')

me = T{}
known_spells = T{} -- keep these separate to avoid bloating me data
ability_recasts = T{}
buffactive = T{}
buffidactive = T{}
event_pauses = event_pauses or T{} -- used to track event pauses (movement, zoning, NPC locks)

local bag_keys = { [0] = 'inventory', [5] = 'satchel', [6] = 'sack', [7] = 'case' }
local food_timer = nil



-------------------------------------------------------------------------------------------------------------------
-- Builds the me table from the shim's player data and adds in additional flags
-------------------------------------------------------------------------------------------------------------------
function build_me_table()
	local p = windower.ffxi.get_player()
	if not p or not p.id then
		return
	end

	me = T{}
	me.id = p.id
	me.name = p.name
	me.hp, me.mp, me.hpp, me.mpp = p.hp, p.mp, p.hpp, p.mpp
	me.main_job_id, me.main_job, me.main_job_level = p.main_job_id, p.main_job, p.main_job_level
	me.sub_job_id, me.sub_job, me.sub_job_level = p.sub_job_id, p.sub_job, p.sub_job_level
	me.JA_locked = false
	me.status = nil -- TODO(ashita): status and buff changes come from packets, not polling

	-- TODO(ashita): zone name lookup for the cities check; treated as not in town until ported
	me.in_town = false

	update_me_party()
	update_me_food_locations(true)
	-- TODO(ashita): BLU spells (Windower used get_mjob_data), port once the spell list source is verified
	me.blu_spells = T{}
end



-------------------------------------------------------------------------------------------------------------------
-- Rebuilds me's party table and sets the me.can_summon_trusts and me.has_trust_target flags
-------------------------------------------------------------------------------------------------------------------
function update_me_party()
	local members = windower.ffxi.get_party() or {}
	me.party = T{}
	for i, m in ipairs(members) do
		me.party[i] = m.name
	end
	-- APPROXIMATION: Windower also allowed trust summoning when the player leads the party.
	-- TODO(ashita): read the party leader and alliance counts to match that rule.
	me.can_summon_trusts = #members <= 1
	-- TODO(ashita): trust detection (Windower used mob.spawn_type == 14)
	me.has_trust_target = false
end



-------------------------------------------------------------------------------------------------------------------
-- Rebuilds me's food_locations immediately on item use and delayed on item moves
-- Frontloaded to do the processing on the rare event (item move/use) and no processing on the common event (make_decision)
-------------------------------------------------------------------------------------------------------------------
function update_me_food_locations(immediate, item_used)
	-- ITEM ADD/REMOVE/USE: IGNORE NON-SKILLUP-FOOD ITEM USES
	if item_used then
		local is_food = skillup_foods:find(function(food) return item_used.id == food.id end)
		if not is_food then
			return logger(chat_colors.purple, '[MISC ITEM MOVED] Ignoring non-skillup food item.', true)
		end
	end

	-- ITEM ADD/REMOVE/USE: RESCHEDULE TO IGNORE ITEM ADD/REMOVE/USE SPAM
	if not immediate then
		if food_timer then
			compat.cancel(food_timer)
		end
		food_timer = coroutine.schedule(function() update_me_food_locations(true, item_used) end, 3)
		return logger(chat_colors.purple, '[SKILLUP FOOD MOVED] Rebuilding food locations in 3 secs...', true)
	end
	food_timer = nil

	-- BUILD FOOD LOCATIONS & HAS_SKILLUP_FOOD FLAG
	logger(chat_colors.purple, '[FOOD LOCATION UPDATE] Rebuilding food locations' .. (item_used and ' due to item usage' or '') .. '...', true)
	local bags = windower.ffxi.get_items()
	me.inventory_full = bags.count_inventory >= bags.max_inventory -- cache to reduce use_module's processing
	me.has_skillup_food = false

	-- food_locations[food_tier][bag_tier] = sorted list of slots
	local food_locations = {}
	for food_tier = 1, #skillup_foods do
		food_locations[food_tier] = {}
		for bag_tier = 1, #bags_ordered do
			food_locations[food_tier][bag_tier] = {}
		end
	end

	-- LOOP THROUGH ITEM BAGS (ENABLED ONES ONLY)
	for bag_tier, container in ipairs(bags_ordered) do
		local key = bag_keys[container]
		if key and bags['enabled_' .. key] then
			for slot, item in pairs(bags[key]) do
				for food_tier, food in ipairs(skillup_foods) do
					if item.id == food.id then
						table.insert(food_locations[food_tier][bag_tier], slot)
						me.has_skillup_food = true
						break
					end
				end
			end
		end
	end

	-- BUILD BEST/AVAILABLE FOOD FLAGS (lower food_tier index is the more potent food)
	me.best_overall_food = nil
	me.best_inventory_food = nil
	for food_tier, food in ipairs(skillup_foods) do
		for bag_tier, slots in ipairs(food_locations[food_tier]) do
			if #slots > 0 then
				table.sort(slots)
				if not me.best_overall_food then
					me.best_overall_food = T{id = food.id, en = food.en, bag = bags_ordered[bag_tier], slot = slots[1]}
				end
				-- bags_ordered[1] is the Inventory container
				if bag_tier == 1 and not me.best_inventory_food then
					me.best_inventory_food = T{id = food.id, en = food.en}
				end
			end
		end
	end

	-- DROP FOOD MODULE IF APPLICABLE
	if not me.has_skillup_food and modules and modules.food and modules.food.active then
		windower.send_command('sms togm silent food')
		logger(chat_colors.red, '[FOOD MODULE DEACTIVATED] No more skillup food in available bags.')
	end
end



-------------------------------------------------------------------------------------------------------------------
-- Refreshes me's vitals from the shim (replaces the Windower char update packets; TODO(ashita): hook packets)
-------------------------------------------------------------------------------------------------------------------
function update_me_vitals()
	local p = windower.ffxi.get_player()
	if not p then return end
	me.hp, me.mp, me.hpp, me.mpp = p.hp, p.mp, p.hpp, p.mpp
end



-------------------------------------------------------------------------------------------------------------------
-- Refreshes me's job and levels (replaces the Windower job change packet; TODO(ashita): hook the packet)
-- Returns true when the job or a level changed, so the caller can re-initialize.
-------------------------------------------------------------------------------------------------------------------
function update_me_job()
	local p = windower.ffxi.get_player()
	if not p then return false end
	local changed = me.main_job_id ~= p.main_job_id or me.main_job_level ~= p.main_job_level
		or me.sub_job_id ~= p.sub_job_id or me.sub_job_level ~= p.sub_job_level
	me.main_job_id, me.main_job, me.main_job_level = p.main_job_id, p.main_job, p.main_job_level
	me.sub_job_id, me.sub_job, me.sub_job_level = p.sub_job_id, p.sub_job, p.sub_job_level
	if changed then
		logger(chat_colors.purple, '[JOB CHANGE] Job changed to ' .. me.main_job .. me.main_job_level .. '/' .. me.sub_job .. me.sub_job_level .. ', re-initializing...', true)
	end
	return changed
end
