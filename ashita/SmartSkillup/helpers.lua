-- Ported from the Windower helpers.lua (Copyright 2022, RolandJ, BSD 3-Clause; see the original in the repo root).
-- Ported so far: logger, reports, session toggles, spell validity and weighting, main skills, skill data processing.
-- TODO(ashita): begin_loop, event pauses, status/buff processing, determine_modules, and skill_data_request_timeout
--   (needs the skill packet request and response, which are not ported yet).

-- Shared state that the Windower main file declares; initialized here until that file is ported.
valid_spells = valid_spells or T{}
valid_spells_sorted = valid_spells_sorted or T{}
ignored_spells = ignored_spells or T{}
known_spells = known_spells or T{}
main_skills = main_skills or T{}

-- UI is not ported yet; ui.* calls are no-ops until the ImGui pass.
ui = ui or setmetatable({}, { __index = function() return function() end end })

-- ASCII stand-ins for the Windower chars glyphs used in the spell report.
chars = chars or { wcircle = 'o', bcircle = 'x', ref = '-', circlejot = '*' }

local sms_res = require('sms_res')

-------------------------------------------------------------------------------------------------------------------
-- A convenient logger that prefixes every message
-- NOTE: chat colors are ignored; the shim prints to the Ashita log.
-------------------------------------------------------------------------------------------------------------------
debugModes = T{norm=false, deep=false}
function logger(color, msg, isDebugMsg, deepDebugMsg)
	if isDebugMsg == nil or (debugModes.norm and isDebugMsg) or (debugModes.deep and deepDebugMsg) then
		windower.add_to_chat(color, '[SmartSkillup] ' .. tostring(msg))
	end
end



-------------------------------------------------------------------------------------------------------------------
-- The end-of-session report generation, provides count of casts and skill levels gained
-------------------------------------------------------------------------------------------------------------------
function print_skillup_report()
	local reported = false
	for skill_en, data in pairs(main_skills) do
		local gained_levels = (data.level or 0) - (data.level_init or 0)
		if data.casts > 0 or gained_levels > 0 then
			reported = true
			logger(chat_colors.grey, '   [' .. skill_en .. '] ' .. data.casts .. ' casts' .. (gained_levels > 0 and (' (+' .. gained_levels .. ' levels)') or ''))
		end
		logger(chat_colors.purple, '   [' .. skill_en .. '] Initial: ' .. tostring(data.level_init) .. ', Current: ' .. tostring(data.level), true)
		data.casts = 0 -- reset this var now to prepare for the next session
	end
	if not reported then logger(chat_colors.grey, '   Nothing to report...') end
end



-------------------------------------------------------------------------------------------------------------------
-- The spell availability report, helps users understand which spells SmartSkillup is using, and why
-------------------------------------------------------------------------------------------------------------------
function print_spell_availability(show_weight)
	logger(chat_colors.grey, '[SPELL REPORT] Printing your spell ' .. (show_weight and 'weight' or 'availability') .. ' report...')
	logger(chat_colors.grey, 'NOTE: Only spells your ' .. me.main_job .. me.main_job_level .. '/' .. me.sub_job .. me.sub_job_level .. ' knows & can cast/skillup on.')
	if show_weight then
		logger(chat_colors.grey, 'NOTE: Spells are weighted equally by MP cost and cast time.')
		logger(chat_colors.grey, 'LEGEND: Spells are prefixed by spell weight; lower is better.')
	else
		logger(chat_colors.grey, 'LEGEND: ' .. chars.wcircle .. ' SmartSkillup will use these spells')
		logger(chat_colors.grey, 'LEGEND: ' .. chars.bcircle .. ' SmartSkillup ignores these spells')
	end
	for skill_en, spells in pairs(valid_spells_sorted) do
		logger(chat_colors.grey, '  ' .. chars.ref .. ' ' .. skill_en:upper())
		if not main_skills[skill_en].parent then
			-- PRINT VALID SPELLS
			for _, spell in pairs(spells) do
				local prefix = show_weight and string.format("%.0f", spell.weight*100) or chars.wcircle
				logger(chat_colors.grey, '      ' .. prefix .. ' ' .. spell.en)
			end

			-- PRINT IGNORED SPELLS (don't do this for the weighted variant, though)
			if not show_weight then
				for _, spell in pairs(ignored_spells[main_skills[skill_en].parent or skill_en] or {}) do
					logger(chat_colors.grey, '      ' .. chars.bcircle .. ' ' .. spell.en .. ' (' .. spell.reason .. ')')
				end
			end

			-- PRINT NO-SPELLS PLACEHOLDER (main job can skill it but player has no spells yet)
			if #spells == 0 and #(ignored_spells[main_skills[skill_en].parent or skill_en] or {}) == 0 then
				logger(chat_colors.grey, '      ' .. chars.bcircle .. ' No available spells')
			end
		else
			logger(chat_colors.grey, '      ' .. chars.circlejot .. ' See "' .. main_skills[skill_en].parent:upper() .. '"')
		end
	end
	logger(chat_colors.grey, 'End of spell report...')
end



-------------------------------------------------------------------------------------------------------------------
-- A toggle that adds support for allowing a player to skill multiple skills in one session
-------------------------------------------------------------------------------------------------------------------
toggle_to_next_skill = function(cap_event)
	if #skills_to_skillup == 0 then
		skill_to_skillup = nil
		if not active then return end
		return coroutine.schedule(function()
			logger(chat_colors.yellow, '[END OF SESSION] No skills remain in the current session. Ending session...')
			if cap_event and auto_shutdown then
				if me.status == 'Engaged' then
					me.shutdown_awaiting_disengage = true
				else
					windower.send_command('input /shutdown')
					logger(chat_colors.yellow, '[AUTO-SHUTDOWN] Performing the requested /shutdown.')
				end
			else
				windower.send_command('sms stop')
			end
		end, 1) --delay for correct log order
	end

	local current_index = skills_to_skillup:find(skill_to_skillup) or 0
	local desired_index = current_index < #skills_to_skillup and current_index + 1 or 1 -- increment unless on max index, goto 1 if so
	skill_to_skillup = skills_to_skillup[desired_index]
end



-------------------------------------------------------------------------------------------------------------------
-- A function that removes a skill from the skill session and handles termination, if applicable
-------------------------------------------------------------------------------------------------------------------
remove_skill_from_session = function(skill_en, cap_event)
	logger(chat_colors.purple, 'Removing ' .. skill_en .. ' from the session...', true)
	if not skills_to_skillup:find(skill_en) then --this skill isn't in the session
		if not cap_event then
			return logger(chat_colors.red, '[REMOVE] Attempted to remove not-in-session ' .. skill_en .. ', why?', true)
		end
	elseif #skills_to_skillup >= 1 then
		if skills_to_skillup:find(skill_en) then
			skills_to_skillup:delete(skill_en)
			toggle_to_next_skill(cap_event)
			ui.button_active(skill_en, false)
		else
			return logger(chat_colors.purple, '[REMOVE ISSUE] Cannot remove "' .. skill_en .. '", it is not the skill_to_skillup (' .. tostring(skill_to_skillup) .. ')', true)
		end
	else
		return logger(chat_colors.red, '[REMOVE] Unhandled skill cap event. Why?', true)
	end
end



-------------------------------------------------------------------------------------------------------------------
-- Processes spells to determine if the player's main job can skill them up
-------------------------------------------------------------------------------------------------------------------
function is_valid(spell, skill_en, for_module) --half of this function came from SMD111
	if not known_spells[spell.id] then --player doesn't know
		return false
	elseif (not spell.levels[me.main_job_id] or spell.levels[me.main_job_id] > me.main_job_level) --mj can't cast
	and (not spell.levels[me.sub_job_id] or spell.levels[me.sub_job_id] > me.sub_job_level) then --sj can't cast
		return false
	elseif skill_en == 'Blue Magic' and not me.blu_spells:find(spell.en) then
		spell.reason = 'Unset'
		if not for_module then ignored_spells[skill_en]:insert(spell) end -- process, but don't insert, while generating modules
		return false
	elseif not for_module and (resistable_spells[skill_en] or T{}):contains(spell.en) then --resistable and bad for skillup
		spell.reason = 'Resistable/unstackable, poor for skillup'
		ignored_spells[skill_en]:insert(spell)
		return false
	elseif not for_module and (spell.en:wmatch('Teleport-*|Raise*|Warp*|Tractor*|Retrace|Escape|Geo-*|Sacrifice|Odin|Alexander|Recall-*|Full Cure')
	or (skill_en == 'Healing Magic' and spell.en:sub(-2) == 'na')) then --not for skillup
		spell.reason = 'Not for skillup'
		ignored_spells[skill_en]:insert(spell)
		return false
	end
	return true
end



-------------------------------------------------------------------------------------------------------------------
-- Get the mj-relevant spells known by the player and weight them
-------------------------------------------------------------------------------------------------------------------
function get_valid_spells()
	-- RE-INITIALIZE VALID SPELL TABLE
	valid_spells = T{}
	ignored_spells = T{}
	for skill_en, data in pairs(main_skills) do
		valid_spells[skill_en] = T{}
		ignored_spells[skill_en] = T{}
		for _, data in pairs(indirect_skills[skill_en] or {}) do --these rely on its spells
			valid_spells[data.en] = T{}
			ignored_spells[data.en] = T{}
		end
	end

	-- PROCESS EACH SPELL
	known_spells = T(windower.ffxi.get_spells() or {}) --known spells, all jobs
	local skill_names = {}
	for _, spell in ipairs(sms_res.all_spells()) do
		if spell.skill ~= 0 then --trusts
			skill_names[spell.skill] = skill_names[spell.skill] or sms_res.skill_name(spell.skill)
			local skill_en = skill_names[spell.skill]
			if skill_en and main_skills[skill_en] and is_valid(spell, skill_en) then
				valid_spells[skill_en][spell.id] = spell
				for _, data in pairs(indirect_skills[skill_en] or {}) do --these rely on its spells
					valid_spells[data.en][spell.id] = spell
				end
			end
		end
	end

	-- PREPARE MAX MEASUREMENTS FOR WEIGHTING
	local meta = T{max_mp_cost = T{}, max_cast_time = T{}} -- metadata on maxes per skill
	for skill_en, spells in pairs(valid_spells) do
		meta.max_mp_cost[skill_en], meta.max_cast_time[skill_en] = 0, 0
		for id, spell in pairs(spells) do
			meta.max_mp_cost[skill_en]   = math.max(meta.max_mp_cost[skill_en]   or 0, spell.mp_cost  )
			meta.max_cast_time[skill_en] = math.max(meta.max_cast_time[skill_en] or 0, spell.cast_time)
		end
	end

	-- BUILD SPELLS SORTED BY WEIGHT
	valid_spells_sorted = T{}
	for skill_en, spells in pairs(valid_spells) do
		valid_spells_sorted[skill_en] = T{}
		for id, spell in pairs(spells) do
			-- CALCULATE/ASSIGN WEIGHT AND PUSH EACH SPELL TO NEW TABLE
			local mp_cost_weight   = meta.max_mp_cost[skill_en] > 0 and math.max(0, spell.mp_cost   / meta.max_mp_cost[skill_en]   * 0.5) or 0 --50% weight
			local cast_time_weight = meta.max_cast_time[skill_en] > 0 and math.max(0, spell.cast_time / meta.max_cast_time[skill_en] * 0.5) or 0 --50% weight
			spell.weight = mp_cost_weight + cast_time_weight
			valid_spells_sorted[skill_en]:insert(spell)
		end
		-- SORT NEW TABLE BY WEIGHT (LOWEST IS BEST)
		table.sort(valid_spells_sorted[skill_en], function(a,b) return a.weight < b.weight end)
	end
end



-------------------------------------------------------------------------------------------------------------------
-- Get the magic skills that are native to the main job (it can only skill-up these skills)
-------------------------------------------------------------------------------------------------------------------
function get_main_skills()
	main_skills = T{}
	-- PROCESS ALL SPELLS (only these can be skilled up by said main job!)
	for _, spell in ipairs(sms_res.all_spells()) do
		if spell.skill ~= 0 then --trusts
			local skill_en = sms_res.skill_name(spell.skill)
			-- INITIALIZE MAIN JOB SKILLS
			if skill_en and main_skills[skill_en] == nil and spell.levels[me.main_job_id] and not ignore_main_spells:find(spell.en) then --main job can cast it
				main_skills[skill_en] = T{id=spell.skill, en=skill_en, casts=0}
				valid_spells[skill_en] = T{}
				-- INITIALIZE INDIRECT SKILLS ALSO (Ex: Wind and String are both tied to Singing)
				for _, indirect_skill in pairs(indirect_skills[skill_en] or {}) do
					main_skills[indirect_skill.en] = indirect_skill
					valid_spells[indirect_skill.en] = T{}
				end
			end
		end
	end
	me.no_magic_skills = main_skills:length() == 0
end



-------------------------------------------------------------------------------------------------------------------
-- Increment relevant cast count for main_skills on each aftercast event
-- event.res.skill is a skill id from the resource manager
-------------------------------------------------------------------------------------------------------------------
function increment_casts(event)
	if event.res == nil or event.res.skill == nil then return end
	local skill_en = sms_res.skill_name(event.res.skill)
	if not skill_en or not main_skills[skill_en] then return end
	main_skills[skill_en].casts = main_skills[skill_en].casts + 1
end



-------------------------------------------------------------------------------------------------------------------
-- Unpack the skill packet into level/capped data for main_skills. Initialize UI on first round.
-- The skill packet source is not ported yet; packet is a table keyed like the Windower packet fields.
-------------------------------------------------------------------------------------------------------------------
function process_skill_data(packet)
	logger(chat_colors.purple, '[SKILL DATA] Processing incoming skill level/cap data...', true)
	for skill, data in pairs(main_skills) do
		local level, capped = packet[skill .. ' Level'], packet[skill .. ' Capped']
		-- CAPTURE INITIAL LEVEL
		if data.level == nil then
			data.level_init, data.capped = level, capped
		else
			-- SKILL UP
			if level ~= data.level then
				ui.set_subtext(data.en, level)
			end
			-- SKILL CAP/UNCAP (uncap on levelup)
			if capped ~= data.capped and not me.awaiting_initialize then
				if capped then
					logger(chat_colors.green, '[SKILL CAP] Congratulations, "' .. skill .. '" skill has capped!')
					remove_skill_from_session(data.en, true)
				end
				ui.set_text_color(skill, capped and 'blue' or 'white')
			end
		end
		data.level, data.capped = level, capped
	end

	-- INITIALIZE UI (ON FIRST DATA RETRIEVAL)
	if not skill_data_retrieved then
		skill_data_retrieved = true
		if initialize_ui then initialize_ui('Initial skill retrieval') end
	end
end
