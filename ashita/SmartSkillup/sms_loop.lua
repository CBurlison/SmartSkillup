-- Ported from the Windower SmartSkillup.lua decision loop (timeouts, make_decision, begin_loop).
-- use_module lives in modules.lua. Cast and action packets (0x028/0x029) are handled here, as are status pauses and auto-rest.
-- Not ported yet: moogle handling.

local sms_res = require('sms_res');
threads = threads or {};
loop = loop or T{ issues = 0 };
decision = decision or T{};
skills_to_skillup = skills_to_skillup or T{};
event_pauses = event_pauses or T{};
active = active or false;
going = going or false;
paused = paused or false;
auto_resting = auto_resting or false;
force_stop_cast = force_stop_cast or false;

-------------------------------------------------------------------------------------------------------------------
-- A function where we decide whether or not to rest after running out of MP or make_decision tries
-------------------------------------------------------------------------------------------------------------------
function decide_to_rest(source, give_countdown, override)
    source = source or 'UNDEFINED';
    logger(chat_colors.purple, '[DECIDE TO REST] Source: ' .. source, true);

    -- RETURN: VALID TARGET
    local target = windower.ffxi.get_mob_by_target('t');
    if me.status == ENGAGED_STATUS then
        return logger(chat_colors.yellow, '[MP NEEDED] Cannot rest while engaged.');
    elseif target and target.claimed and target.hpp > 0 then
        return logger(chat_colors.yellow, '[MP NEEDED] Cannot rest due to valid target "' .. target.name .. '".');
    end

    local battle_target = windower.ffxi.get_mob_by_target('bt');
    if battle_target and battle_target.spawn_type == 16 and battle_target.hpp > 0 and math.sqrt(battle_target.distance) < 20 then
        return logger(chat_colors.yellow, '[MP NEEDED] Cannot rest due to valid target "' .. battle_target.name .. '".');
    end

    -- RETURN: MP NOT NEEDED
    if not decision.out_of_mp and me.mpp > 30 then
        return logger(chat_colors.purple, '[PROCESS RESTING] CANCEL: MP Needed flag is false and player MPP above 30.', true);
    -- RETURN: ALREADY RESTING
    elseif me.status == RESTING_STATUS or event_pauses.Resting then
        return;
    end

    -- BEGIN RESTING
    loop.issues = 0;
    auto_resting = true;
    end_timeout_and_decision(source);
    if give_countdown then
        initialize_healing_notice(10, source .. (override and ' <30% MP' or ''), true);
    else
        windower.send_command('input /heal');
    end
    return true;
end

-------------------------------------------------------------------------------------------------------------------
-- Functions to keep the loop/timeout mechanism functioning in a uniform/legible/debuggable manner
-------------------------------------------------------------------------------------------------------------------
function start_timeout(delay, source)
    threads.timeout = process_event:schedule(delay or 1, { timeout = true, source = source });
    logger(chat_colors.purple, '[TIMEOUT START] Timeout started in ' .. (delay or 1) .. ' secs' .. (source and ' by ' .. source or '') .. '.', false, true);
end

function end_timeout(source)
    if threads.timeout then
        pcall(coroutine.close, threads.timeout);
        threads.timeout = nil;
    end
    logger(chat_colors.purple, '[TIMEOUT END] Timeout ended' .. (source and ' by ' .. source or '') .. '.', false, true);
end

function schedule_decision(delay, source, ...)
    threads.make_decision = make_decision:schedule(delay, source);
    local args = { ... };
    if args[2] then logger(...); end
end

function end_decision()
    if threads.make_decision then
        pcall(coroutine.close, threads.make_decision);
        threads.make_decision = nil;
    end
end

function end_timeout_and_decision(source, ...)
    end_timeout(source or 'end_timeout_and_decision');
    end_decision();
    local args = { ... };
    if args[2] then logger(...); end
end

function process_event(event)
    local pauses = {};
    for name, value in pairs(event_pauses) do
        if value then table.insert(pauses, name); end
    end
    if not active or paused then
        return logger(chat_colors.purple, '[EVENT CANCEL] SMS inactive or paused. (timeout: ' .. tostring(event.timeout) .. ')', true);
    elseif #pauses > 0 then
        return logger(chat_colors.purple, '[EVENT CANCEL] Event pauses active: ' .. table.concat(pauses, ', ') .. ' (timeout: ' .. tostring(event.timeout) .. ')', true);
    end

    if event.timeout then
        logger(chat_colors.purple, '[TIMEOUT] Making a new decision.', true);
        make_decision(event.source);
        return;
    end

    local reason = event.stage:upper() .. ' EVENT' .. larr .. (event.res and event.res.en or event.name):upper();
    -- MIDCAST: AN ACTION STARTED (wait for the cast to finish before the next decision)
    if event.stage == 'midcast' then
        decision.stage = 'midcast';
        local cast_time = event.res and event.res.cast_time or 0;
        local aftercast_delay = cast_time * (buffactive.Addle and 1.2 or 1) + 2.5;
        end_timeout_and_decision(reason);
        logger(chat_colors.purple, '[' .. reason .. '] Scheduled a timeout in ' .. aftercast_delay .. ' secs.', true);
        start_timeout(aftercast_delay, reason);

    -- AFTERCAST: AN ACTION ENDED
    elseif event.stage == 'aftercast' and not me.moving then
        decision.stage = 'aftercast';
        increment_casts(event);
        end_timeout_and_decision(reason); -- interrupts skip midcast, so the pending timeout is cleared here too
        schedule_decision(2, reason, chat_colors.purple, '[' .. reason .. '] Scheduled a decision in 2 secs.', true);

        -- TRACK ACTIVE INDICOLURE
        if (event.name == 'Casting Completed' or event.name == 'Already Active') and event.res and event.res.en:sub(1, 5) == 'Indi-' then
            me.indicolure = event.res.en;
            logger(chat_colors.purple, '[INDICOLURE] "' .. event.res.en .. '" is active...', true);
        end
    end
end

-------------------------------------------------------------------------------------------------------------------
-- Action (0x028) and action message (0x029) handling, ported from Windower process_action and process_action_message_packet
-------------------------------------------------------------------------------------------------------------------
function process_action(act)
    if not act.actor_id or act.actor_id ~= me.id then return; end
    logger(chat_colors.purple, '[ACTION PACKET] category ' .. tostring(act.category) .. ', param ' .. tostring(act.param) .. ', targets ' .. #act.targets, true);

    -- CASTING STARTED
    if act.category == 8 and act.param ~= 28787 then
        local target = act.targets[1];
        local spell_id = target and target.actions[1] and target.actions[1].param;
        process_event({ name = 'Casting Started', stage = 'midcast', timeout = false, res = spell_id and sms_res.spell_by_id(spell_id) });

    -- CASTING INTERRUPTED
    elseif act.category == 8 then
        process_event({ name = 'Casting Interrupted', stage = 'aftercast', timeout = false });

    -- CASTING COMPLETED
    elseif act.category == 4 then
        process_event({ name = 'Casting Completed', stage = 'aftercast', timeout = false, res = sms_res.spell_by_id(act.param) });

    -- JOB ABILITY USED (ability names are not looked up yet, so no res is passed)
    elseif act.category == 6 then
        process_event({ name = 'Job Ability Used', stage = 'aftercast', timeout = false });

    -- ITEM STARTED (item lookups are not ported yet, so no res is passed)
    elseif act.category == 9 and act.param == 24931 then
        process_event({ name = 'Item Started', stage = 'midcast', timeout = false });

    -- ITEM INTERRUPTED
    elseif act.category == 9 then
        process_event({ name = 'Item Interrupted', stage = 'aftercast', timeout = false });

    -- ITEM COMPLETED (food locations refresh on a timer in use_module, not on this event)
    elseif act.category == 5 then
        process_event({ name = 'Item Completed', stage = 'aftercast', timeout = false });
    end
end

function process_action_message(msg)
    -- UNABLE TO CAST
    if msg.message == 17 or msg.message == 18 then
        process_event({ name = 'Unable to Cast', stage = 'aftercast', timeout = false });

    -- EFFECT ALREADY ACTIVE
    elseif msg.message == 523 then
        process_event({ name = 'Already Active', stage = 'aftercast', timeout = false, res = sms_res.spell_by_id(msg.param1) });

    -- SPELL LEARNED (standard and blue magic)
    elseif msg.message == 23 or msg.message == 419 then
        get_valid_spells();
        logger(chat_colors.purple, '[SPELL LEARNED] Rebuilt valid spells.', true);
    end
end

-------------------------------------------------------------------------------------------------------------------
-- Event pauses (NPC locks, zoning). Ported from the Windower event_pauses_metatable: a pause ends an active loop,
-- and the loop restarts once the last pause ends.
-------------------------------------------------------------------------------------------------------------------
local function count_event_pauses()
    local count = 0;
    for _, value in pairs(event_pauses) do
        if value then count = count + 1; end
    end
    return count;
end

local function set_event_pause(event, value)
    local start_count = count_event_pauses();
    event_pauses[event] = value;
    local end_count = count_event_pauses();

    -- EVENT PAUSE STARTED
    if start_count == 0 and end_count > 0 then
        local reason = 'PAUSE EVENT' .. larr .. event:upper();
        if not active or paused then
            logger(chat_colors.lpurple, '[' .. reason .. '] Ignored, inactive or player-paused.', true);
        else
            going = false;
            end_timeout_and_decision(reason, chat_colors.purple, '[' .. reason .. '] "' .. event .. '" started an event pause and ended the timeout and decisions.', true);
        end

    -- EVENT PAUSE ENDED
    elseif end_count == 0 and start_count > 0 then
        local reason = 'UNPAUSE EVENT' .. larr .. event:upper();
        if going and not me.awaiting_event_pause_end then
            logger(chat_colors.lpurple, '[' .. reason .. '] Ignored, loop already going.', true);
        elseif not active or paused then
            logger(chat_colors.lpurple, '[' .. reason .. '] Ignored, inactive or player-paused.', true);
        else
            going = true;
            me.awaiting_event_pause_end = nil;
            end_timeout_and_decision(reason);
            schedule_decision(1, reason, chat_colors.purple, '[' .. reason .. '] The last event, "' .. event .. '", scheduled a decision in 1 sec...', true);
        end

    -- A NESTED EVENT STARTED OR ENDED
    else
        local mode = value and 'pause' or 'unpause';
        logger(chat_colors.lpurple, '[' .. mode:upper() .. ' EVENT' .. larr .. event:upper() .. '] Ignored a nested "' .. event .. '" ' .. mode .. '.', false, true);
    end
end

function pause_event(event)
    local key = 'sched_' .. event .. '_unpause';
    if threads[key] then
        pcall(coroutine.close, threads[key]); -- the event is pausing again, so its pending unpause would be premature
        threads[key] = nil;
    end
    set_event_pause(event, true);
end

function unpause_event(event, delay)
    threads['sched_' .. event .. '_unpause'] = coroutine.schedule(function()
        set_event_pause(event, nil);
    end, delay or 0);
end

-------------------------------------------------------------------------------------------------------------------
-- Status pauses, resting, and the healing notice (Windower's process_status_change and helpers)
-- Status ids are the Windower/FFXI status codes. Only the names used in logs and pauses are listed.
-------------------------------------------------------------------------------------------------------------------
local STATUS_NAMES = {
    [0] = 'Idle', [1] = 'Engaged', [2] = 'Dead', [3] = 'Engaged dead', [4] = 'Event', [5] = 'Chocobo',
    [8] = 'Door Opening', [9] = 'Door Closing', [10] = 'Elevator Up', [11] = 'Elevator Down',
    [33] = 'Resting', [34] = 'Locked', [44] = 'Crafting', [47] = 'Sitting', [48] = 'Kneeling', [85] = 'Mount',
};

local function status_name(id)
    return STATUS_NAMES[id] or ('Status ' .. id);
end

local function process_status_events(newStatusId, oldStatusId)
    -- STATUS PAUSE EVENTS -- Dead, Chocobo, Cutscene, Resting, etc
    if newStatusId > 1 then
        if newStatusId == RESTING_STATUS then terminate_healing_notice('Status change'); end
        pause_event(status_name(newStatusId));
    end
    if oldStatusId and oldStatusId > 1 then
        unpause_event(status_name(oldStatusId), 1);
    end
end

local function processing_resting_change(newStatusId, oldStatusId)
    if not active or paused then return; end
    if newStatusId ~= RESTING_STATUS and oldStatusId ~= RESTING_STATUS then return; end

    -- STARTED RESTING
    if newStatusId == RESTING_STATUS then
        me.healing_countdown_running = nil;
        me.finish_rest_sent = nil;
        if auto_resting or me.mpp < 70 then -- ignore rests where the player is apparently arbitrarily healing
            logger(chat_colors.yellow, '[RESTING] Skillup will resume automatically when MP is full.');
            auto_resting = true; -- will get up when full
        end

    -- GOT UP FROM RESTING
    else
        auto_resting = false;
        me.getting_up = true; -- used to track get-up animation lock
        coroutine.schedule(function() me.getting_up = nil; end, 1.5);
    end
end

function initialize_healing_notice(total_delay, reason, first)
    me.healing_countdown_running = true;
    total_delay = total_delay or 9; -- total time till alert expires
    local next_tick = total_delay <= 3 and 1 or math.fmod(total_delay, 3) == 0 and 3 or math.fmod(total_delay, 3) + 3;
    if total_delay > 0 then
        logger(chat_colors.yellow, '[RESTING SCHEDULED] Beginning a resting session in ' .. total_delay .. ' seconds...' .. (first and ' (Reason: ' .. reason .. ')' or ''));
        threads.healing_notice = initialize_healing_notice:schedule(next_tick, total_delay - next_tick, reason);
    else
        auto_resting = true;
        me.healing_countdown_running = nil;
        windower.send_command('input /heal');
    end
end

function terminate_healing_notice(reason)
    if threads.healing_notice then
        pcall(coroutine.close, threads.healing_notice);
        threads.healing_notice = nil;
    end
    if me.healing_countdown_running then
        me.healing_countdown_running = nil;
        logger(chat_colors.yellow, '[RESTING CANCELLED] Cancelled the scheduled healing session.' .. (reason and ' (Reason: ' .. reason .. ')' or ''));
    end
end

function process_status_change(newStatusId, oldStatusId)
    process_status_events(newStatusId, oldStatusId);
    processing_resting_change(newStatusId, oldStatusId);

    if not active then return; end
    if oldStatusId == RESTING_STATUS and not paused then
        me.getting_up = true;
        coroutine.schedule(function() me.getting_up = nil; end, 3);
    end

    -- PLAYER IS ENGAGED
    if newStatusId == ENGAGED_STATUS then
        terminate_healing_notice('Player engaged');
        if not paused then
            begin_loop('PLAYER ENGAGED', true);
        end

    -- DISENGAGEMENT
    elseif newStatusId == 0 and oldStatusId == ENGAGED_STATUS then
        if me.shutdown_awaiting_disengage then
            windower.send_command:schedule(2, 'input /shutdown');
            return logger(chat_colors.yellow, '[AUTO-SHUTDOWN] Performing the requested /shutdown.');
        end

        local override = not auto_resting and me.mpp < 30;
        if auto_resting or override then
            decide_to_rest('Player disengaged', true, override);
        end
    end
end

-- Polled from the d3d_present tick, since the status packets are not ported. Detects status changes and ends auto-rest at full MP.
function check_status_change()
    if not me.id then return; end
    local new_id = windower.ffxi.get_status();
    local old_id = me.status;
    if new_id ~= old_id then
        me.status = new_id;
        update_me_vitals();
        process_status_change(new_id, old_id);
    end

    -- END OF RESTING SESSION
    if new_id == RESTING_STATUS and active and auto_resting and not me.finish_rest_sent then
        update_me_vitals();
        if me.mpp == 100 then
            me.finish_rest_sent = true;
            logger(chat_colors.purple, '[HEALING FINISHED] Sending the "//sms go" command to continue.', true);
            windower.send_command('sms go "Finished healing"');
        end
    end
end

-------------------------------------------------------------------------------------------------------------------
-- A function to handle processing requests to begin the loop and the situational actions required to do so correctly
-------------------------------------------------------------------------------------------------------------------
function begin_loop(source, notify)
    source = source or 'NEW LOOP';
    logger(chat_colors.purple, '[BEGIN LOOP' .. larr .. source:upper() .. '] Beginning loop...', false, true);
    local verbiage = active and { 'RESUME', 'resuming' } or { 'START', 'starting' };

    -- RETURN: NO SKILLS TO SKILLUP
    if #skills_to_skillup == 0 then
        return logger(chat_colors.red, '[DENIED] No skills have been added to attempt to begin. (TIP: //sms addskill [searchterm])');
    elseif going then
        return logger(chat_colors.purple, '[DENIED] Loop is already going.', true);
    end

    -- ACTIVATE UI TEXT
    active = true;
    ui.active(true);

    -- RETURN: NEED TO START GETTING UP
    if event_pauses.Resting and not me.getting_up then
        me.getting_up = true;
        windower.send_command('input /heal');
        end_timeout_and_decision(source, chat_colors.purple, '[NEW LOOP] Ending any scheduled timeout and decision...', true);
        schedule_decision(3, source .. '+GET UP');
        return logger(chat_colors.green, '[' .. verbiage[1] .. '] Getting up and ' .. verbiage[2] .. ' in 3 seconds...');

    -- RETURN: GET UP FASTER (just wait, the get-up unpause resumes the loop)
    elseif event_pauses.Resting then
        return logger(chat_colors.green, '[START] Resuming skillup session...');
    end

    -- RETURN: AWAITING EVENT PAUSES
    if next(event_pauses) ~= nil then
        me.awaiting_event_pause_end = true; -- required when player unpauses during an event pause
        local names = {};
        for name, value in pairs(event_pauses) do
            if value then table.insert(names, name); end
        end
        return logger(chat_colors.green, '[START] Waiting on the following pause events to end: ' .. table.concat(names, ', '));
    end

    -- RESET VARIOUS VARS
    paused = false;
    ui.paused(false);
    loop.issues = 0;

    -- NOTIFY CLIENT IF NOTIFY TRUE
    logger(chat_colors.green, '[' .. verbiage[1] .. '] Skillup session ' .. verbiage[2] .. '...', not notify and true or nil);

    -- ENSURE SINGLE TIMEOUT, THEN START DECISION
    end_timeout_and_decision(source, chat_colors.purple, '[NEW LOOP] Ending any scheduled timeout and decision...', true);
    going = true;
    make_decision(source);
end

-------------------------------------------------------------------------------------------------------------------
-- The main brains of the skillup loop/timeout
-------------------------------------------------------------------------------------------------------------------
local function count_where(list, predicate)
    local n = 0;
    for _, item in ipairs(list) do
        if predicate(item) then n = n + 1; end
    end
    return n;
end

function make_decision(source) -- must be global to both A) be called from above and B) schedule itself internally
    logger(chat_colors.purple, '[MAKE DECISION] Source: ' .. tostring(source), false, true);

    -- PROCESS EXIT SCENARIOS
    if not active or paused then -- not in a skillup session
        end_timeout();
        return logger(chat_colors.purple, '[DECISION STOP] SmartSkillup ' .. (paused and 'paused' or 'not active') .. ', exiting make_decision.', true);
    elseif skill_to_skillup == nil then -- skillup session with nothing to skillup
        end_timeout('no skills remaining');
        return logger(chat_colors.purple, '[DECISION STOP] CAUSE: No skill to skillup.', true);
    elseif force_stop_cast then -- a temp testing measure
        end_timeout('force stop cast');
        force_stop_cast = false;
        return logger(chat_colors.purple, '[DECISION STOP] Force stopped make_decision and reset force_stop_cast var.', true);
    elseif use_module() then
        start_timeout(2.5, 'module use');
        return logger(chat_colors.purple, '[DECISION STOP] CAUSE: Module being used.', true);
    elseif skill_to_skillup == 'Summoning Magic' and windower.ffxi.get_mob_by_target('pet') then
        start_timeout(1, 'release');
        windower.send_command('input /ja "Release" <me>');
        return logger(chat_colors.purple, '[DECISION STOP] Releasing the player\'s avatar...', true);
    end

    -- Vitals are polled here until the packet handlers are ported.
    update_me_vitals();

    -- DETERMINE & CAST NEXT SPELL
    local spell_recasts = windower.ffxi.get_spell_recasts(); -- keyed by spell id; missing key means ready
    local function recast_of(spell)
        return spell_recasts[spell.id] or 0;
    end
    local spells = valid_spells_sorted[skill_to_skillup];
    local spells_below_limit = mp_limit and count_where(spells, function(s) return s.mp_cost <= mp_limit; end);

    -- PROCESS MP LIMIT ISSUE
    if mp_limit and spells_below_limit == 0 then
        local previous = mp_limit;
        toggle_mp_limit();
        logger(chat_colors.yellow, '[MP LIMIT ISSUE] No "' .. skill_to_skillup .. '" spells available cheaper than ' .. previous .. '; increasing limit to ' .. tostring(mp_limit) .. '.');
    end

    decision = T{ min_recast = 0 };
    for _, spell in ipairs(spells) do
        -- CONTINUE: INDOCOLURE ALREADY ACTIVE
        if spell.en == me.indicolure then -- can't recast active indicolure
            logger(chat_colors.purple, 'SKIP: Skipping ' .. spell.en .. ', indicolure already active...', true);
            if mp_limit and spells_below_limit == 1 then
                toggle_mp_limit();
                logger(chat_colors.yellow, '[MP LIMIT ISSUE] Increasing limit to allow a second indi spell.');
            end

        -- SKIP: SPELL OVER MP_LIMIT (MODULE); spells are weighted by cost and cast time, so cheaper spells may follow
        elseif mp_limit and spell.mp_cost > mp_limit then
            decision.over_mp_limit = true;
            logger(chat_colors.purple, '[SPELL SKIP] Skipping "' .. spell.en .. '" due to being ' .. (spell.mp_cost - mp_limit) .. ' over the MP limit of ' .. mp_limit .. '.', false, true);

        -- CONTINUE: SPELL AWAITING RECAST
        elseif recast_of(spell) > 0 then
            if decision.min_recast == 0 or recast_of(spell) < decision.min_recast then
                decision.best_spell, decision.min_recast = spell, recast_of(spell);
            end

        -- BREAK: WAIT FOR TWICE AS CHEAP SPELL IF READY IN LESS THAN 1.2 SECS
        elseif decision.best_spell and recast_of(decision.best_spell) / 60 < 1.2 and spell.mp_cost / decision.best_spell.mp_cost > 2 then
            decision.awaiting_more_efficient_spell = true;
            logger(chat_colors.purple, '[SPELL BREAK] Broke on "' .. spell.en .. '" due to comparison to "' .. decision.best_spell.en .. '"...', false, true);
            break;

        -- RETURN: CHEAPEST SPELL TOO EXPENSIVE (NEED TO REST)
        elseif me.mp < spell.mp_cost + (me.convert_ready and 1 or 0) then -- ensure 1 MP is left if convert is viable
            logger(chat_colors.red, '[MP NEEDED] Insufficient MP for next spell "' .. spell.en .. '" (MP: ' .. me.mp .. '/' .. spell.mp_cost .. ')');
            decision.out_of_mp = true;
            return decide_to_rest('Out of MP');

        else
            -- RESOLVE TARGET STRING (<me>, <p1>, <t>)
            local target_string = (function()
                -- SELF/PARTY SPELLS (Prefer trusts for ilvl target skillup chance multiplier)
                if spell.targets.Self and spell.targets.Party then
                    for i = 1, 5, 1 do
                        local entity = windower.ffxi.get_mob_by_target('p' .. i);
                        local castable = not untargetable_trusts:contains((entity or {}).name);
                        if entity and entity.spawn_type == 14 and castable and math.sqrt(entity.distance) <= 20 then
                            return '<p' .. i .. '>';
                        end
                    end
                    return '<me>'; -- fallback target

                -- SELF-ONLY SPELLS
                elseif spell.targets.Self then
                    return '<me>';

                -- ENEMY-ONLY SPELLS (<bt> fallback is not ported yet)
                elseif spell.targets.Enemy then
                    local entity = windower.ffxi.get_mob_by_target('t');
                    if entity and entity.spawn_type == 16 and entity.hpp > 0 then
                        if math.sqrt(entity.distance) > 20 then
                            decision.target_issue = { 'Target out of range', spell.en };
                        else
                            return '<t>';
                        end
                    else
                        decision.target_issue = decision.target_issue or { 'Unable to find target', spell.en };
                    end
                end
            end)();

            -- CAST SPELL IF TARGET OBTAINED
            if target_string then
                loop.issues = 0;
                toggle_to_next_skill();
                windower.send_command('input /ma "' .. spell.en .. '" ' .. target_string);
                decision.res = spell;
                decision.stage = 'precast';
                start_timeout(1.5, 'decision');
                logger(chat_colors.purple, '[DECISION] Attempting to cast "' .. spell.en .. '" on ' .. target_string .. '...', true);
                return true;
            end
        end
    end

    -------------------------------------
    -- PAST THIS POINT: ISSUE TERRITORY
    -------------------------------------

    -- TRACK ISSUE COUNT & GET NEXT DECISION DELAY
    loop.issues = loop.issues + 1; -- reset on each successful decision
    me.session_issues = (me.session_issues or 0) + 1; -- reset on OFF
    local delay = decision.min_recast > 0 and (decision.min_recast / 60) + 0.1 --[[recast issue]] or 4 --[[target issue]];

    -- RETURN: REST IF NEEDED ON 10TH ISSUE (player is probably AFK, fill-er-up!)
    if loop.issues == 10 then
        local resting = decide_to_rest('10th Issue', true);
        if resting then return; end
    end

    -- DETERMINE WHEN TO NOTIFY (don't spam the player)
    local notify = (function()
        if loop.issues < 10 then -- once per issue until 10th issue
            return true;
        elseif loop.issues == 10 then -- special notice on 10th issue
            logger:schedule(0.2, chat_colors.yellow, '[IMPORTANT] You will now only be notified once every 10 consecutive issues.');
            return true;
        elseif loop.issues % 10 == 0 and loop.issues < 100 then -- once per 10 until 100
            return true;
        elseif loop.issues == 100 then -- special notice on 100th issue
            logger:schedule(0.2, chat_colors.yellow, '[IMPORTANT] You will now only be notified once every 100 consecutive issues.');
            return true;
        elseif loop.issues % 100 == 0 then -- once per 100 issues from there on out
            return true;
        end
        return false;
    end)();

    -- NOTIFY IF APPLICABLE
    if notify then
        local count_string = ' (Issue #' .. loop.issues .. ')';
        if decision.target_issue then
            toggle_to_next_skill();
            logger(chat_colors.yellow, '[TARGET ISSUE] ' .. decision.target_issue[1] .. ' for "' .. decision.target_issue[2] .. '".' .. count_string);
        elseif decision.min_recast > 0 then
            logger(chat_colors.purple, '[DECISION DELAY] Scheduling a retry in ' .. string.format('%.2f', delay) .. ' due to "' .. decision.best_spell.en .. '" recast timer...' .. count_string, true);
        elseif decision.over_mp_limit then
            -- not mentioned on purpose
        else
            logger(chat_colors.purple, '[DECISION ISSUE] Unable to cast, scheduling another cast in ' .. string.format('%.2f', delay) .. ' seconds...' .. count_string, true);
        end
    end

    -- SCHEDULE NEXT DECISION
    schedule_decision(delay, 'DECISION:ISSUE ' .. loop.issues);
end
