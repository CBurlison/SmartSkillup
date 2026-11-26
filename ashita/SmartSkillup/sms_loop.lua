-- Ported from the Windower SmartSkillup.lua decision loop (timeouts, make_decision, begin_loop).
-- Step 1 of the port. Not ported yet: modules (use_module is a stub), event pauses (only the timeout branch
-- of process_event runs), and auto-rest (decide_to_rest stops the loop instead).

threads = threads or {};
loop = loop or T{ issues = 0 };
decision = decision or T{};
skills_to_skillup = skills_to_skillup or T{};
event_pauses = event_pauses or T{};
active = active or false;
going = going or false;
paused = paused or false;
force_stop_cast = force_stop_cast or false;

-- Modules are step 2. Returning false means no module is in use.
function use_module()
    return false;
end

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

-- Only the timeout branch is ported; real event handling (packets) is step 3.
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
