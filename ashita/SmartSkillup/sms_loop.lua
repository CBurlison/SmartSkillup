-- Ported from the Windower SmartSkillup.lua decision loop (timeouts, make_decision, begin_loop).
-- use_module lives in modules.lua. Cast and action packets (0x028/0x029) are handled here.
-- Not ported yet: status pauses (resting, dead, cutscene), food/moogle handling, and auto-rest (decide_to_rest stops the loop instead).

local sms_res = require('sms_res');
threads = threads or {};
loop = loop or T{ issues = 0 };
decision = decision or T{};
skills_to_skillup = skills_to_skillup or T{};
event_pauses = event_pauses or T{};
active = active or false;
going = going or false;
paused = paused or false;
force_stop_cast = force_stop_cast or false;

-- Auto-rest needs the engaged and claim checks, which are not ported yet. Stop the loop instead of resting.
function decide_to_rest(source)
    end_timeout_and_decision(source or 'decide_to_rest');
    going = false;
    logger(chat_colors.yellow, '[REST NEEDED] ' .. tostring(source) .. '. Auto-rest is not ported yet, so the loop has stopped. Rest, then use /sms go to resume.');
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

    -- ITEM COMPLETED (food location updates are not ported yet)
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
        mp_limit = nil; -- the Windower 'sms mplimit toggle' is not ported yet; lift the limit
        logger(chat_colors.yellow, '[MP LIMIT ISSUE] No "' .. skill_to_skillup .. '" spells available cheaper than the limit; limit lifted.');
    end

    decision = T{ min_recast = 0 };
    for _, spell in ipairs(spells) do
        -- CONTINUE: INDOCOLURE ALREADY ACTIVE
        if spell.en == me.indicolure then -- can't recast active indicolure
            logger(chat_colors.purple, 'SKIP: Skipping ' .. spell.en .. ', indicolure already active...', true);

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

        -- BREAK: SPELL OVER MP_LIMIT (MODULE)
        elseif mp_limit and spell.mp_cost > mp_limit then
            decision.over_mp_limit = true;
            logger(chat_colors.purple, '[SPELL BREAK] Broke on "' .. spell.en .. '" due to being ' .. (spell.mp_cost - mp_limit) .. ' over the MP limit of ' .. mp_limit .. '.', false, true);
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
