-- ImGui window for SmartSkillup (Windower libs/sms_ui.lua, ported). Reads the live session state each frame and
-- sends the same chat verbs the commands use, so button clicks and typed commands share one code path.

local imgui = require('imgui');
local settings = require('settings');

local M = {};

local DEFAULTS = T{ visible = true, scale = 1.0, x = 100, y = 100 };
local cfg = settings.load(DEFAULTS);
-- Re-applies the saved position on the next frame (set on load, character switch, and the layout commands).
local force_layout = true;
local dragging = false;

local COLUMNS = 3;
local BUTTON_WIDTH = 120;
local HEADER_WIDTH = 90;
local BUTTON_HEIGHT = 22;
local BLUE = { 0.25, 0.45, 0.85, 1.0 };
local ORANGE = { 0.85, 0.50, 0.10, 1.0 };
local MODULE_ORDER = { 'convert', 'refresh', 'haste', 'sublim', 'food', 'mp_limit', 'moogle', 't_target' };

settings.register('settings', 'smartskillup_settings_update', function(s)
    cfg = s;
    force_layout = true;
end);

local function scaled(value)
    return math.floor(value * cfg.scale + 0.5);
end

local function color_button(label, color, width)
    if color then imgui.PushStyleColor(ImGuiCol_Button, color); end
    local clicked = imgui.Button(label, { scaled(width or BUTTON_WIDTH), scaled(BUTTON_HEIGHT) });
    if color then imgui.PopStyleColor(); end
    return clicked;
end

-- Geo-Refresh and Radial Arcana are not ported yet, so they are drawn faded and ignore clicks.
local function disabled_button(label, tooltip)
    imgui.PushStyleVar(ImGuiStyleVar_Alpha, 0.4);
    imgui.Button(label, { scaled(BUTTON_WIDTH), scaled(BUTTON_HEIGHT) });
    imgui.PopStyleVar();
    if imgui.IsItemHovered() then
        imgui.BeginTooltip();
        imgui.TextUnformatted(tooltip);
        imgui.EndTooltip();
    end
end

-- Places a grid item: starts a new row at each column boundary, otherwise sits beside the previous item.
local function place(index)
    if (index - 1) % COLUMNS ~= 0 then imgui.SameLine(); end
end

local function in_list(list, value)
    for _, item in ipairs(list or {}) do
        if item == value then return true; end
    end
    return false;
end

local function status_text()
    if not active then return 'Inactive'; end
    if paused then return 'Paused'; end
    return 'Active' .. (skill_to_skillup and (': ' .. skill_to_skillup) or '');
end

local function draw_header()
    if color_button('ON##sms_on', active and ORANGE or nil, HEADER_WIDTH) then windower.send_command('sms go'); end
    imgui.SameLine();
    if color_button('OFF##sms_off', nil, HEADER_WIDTH) then windower.send_command('sms stop'); end
    imgui.SameLine();
    if color_button('PAUSE##sms_pause', paused and ORANGE or nil, HEADER_WIDTH) then windower.send_command('sms pause'); end
    imgui.SameLine();
    if color_button('AUTO-SHUTDOWN##sms_as', auto_shutdown and ORANGE or nil, HEADER_WIDTH) then windower.send_command('sms autoshutdown'); end
    imgui.TextUnformatted(status_text());
end

local function draw_skills()
    local names = {};
    for name in pairs(main_skills or {}) do table.insert(names, name); end
    table.sort(names);

    imgui.TextUnformatted('Skills');
    for i, name in ipairs(names) do
        local skill = main_skills[name];
        place(i);
        local level = skill.level and (' ' .. tostring(skill.level)) or '';
        local color = nil;
        if skill.capped then
            color = BLUE;
        elseif in_list(skills_to_skillup, name) then
            color = ORANGE;
        end
        if color_button(name .. level .. '##skill_' .. name, color) then
            windower.send_command('sms togs ' .. name);
        end
    end
    if #names == 0 then imgui.TextUnformatted('No skills for this job yet.'); end
end

local function draw_modules()
    imgui.TextUnformatted('Modules');
    local count = 0;
    for _, key in ipairs(MODULE_ORDER) do
        local mod = modules and modules[key];
        if mod and mod.available then
            count = count + 1;
            place(count);
            if color_button(mod.label .. '##mod_' .. key, mod.active and ORANGE or nil) then
                windower.send_command('sms togm ' .. key);
            end
            if key == 'mp_limit' then
                imgui.SameLine();
                if color_button('Limit: ' .. tostring(mp_limit or 10) .. '##mp_limit_value', nil) then
                    windower.send_command('sms mplimit toggle');
                end
            end
        end
    end
    place(count + 1);
    disabled_button('Geo-Refresh##geo_refresh', 'Geo-Refresh is not ported yet.');
    place(count + 2);
    disabled_button('Rad. Arcana##rad_arcana', 'Radial Arcana is not ported yet.');
end

-- Drags the window to a new spot and saves its position on mouse release.
local function track_position()
    local wx, wy = imgui.GetWindowPos();
    if imgui.IsWindowHovered() and imgui.IsMouseDown(0) then dragging = true; end
    if dragging and not imgui.IsMouseDown(0) then
        dragging = false;
        local x, y = math.floor(wx), math.floor(wy);
        if x ~= cfg.x or y ~= cfg.y then
            cfg.x, cfg.y = x, y;
            settings.save();
        end
    end
end

-- Draws the window. Called every frame from d3d_present.
function M.render()
    if not cfg.visible then return; end

    imgui.SetNextWindowPos({ cfg.x, cfg.y }, force_layout and ImGuiCond_Always or ImGuiCond_Once);
    local flags = bit.bor(ImGuiWindowFlags_NoResize, ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoSavedSettings);
    imgui.Begin('SmartSkillup##sms_main', true, flags);
    if imgui.SetWindowFontScale then imgui.SetWindowFontScale(cfg.scale); end

    draw_header();
    imgui.Separator();
    draw_skills();
    imgui.Separator();
    draw_modules();

    track_position();
    force_layout = false;
    imgui.End();
end

local function set_scale(value)
    cfg.scale = math.floor(math.max(0.5, math.min(1.5, value)) * 10 + 0.5) / 10;
    settings.save();
    print('[SmartSkillup] UI scale set to ' .. string.format('%.1f', cfg.scale) .. '.');
end

-- Handles the ui* chat commands. Returns true when the verb belongs to the UI.
function M.handle_command(verb, args)
    if verb == 'uihide' then
        cfg.visible = false;
        settings.save();
        print('[SmartSkillup] UI hidden. Use //sms uishow to bring it back.');
    elseif verb == 'uishow' then
        cfg.visible = true;
        settings.save();
        print('[SmartSkillup] UI shown.');
    elseif verb == 'uiscale' then
        local value = tonumber(args);
        if value then
            set_scale(value);
        else
            print('[SmartSkillup] UI scale is ' .. string.format('%.1f', cfg.scale) .. '. Usage: //sms uiscale <0.5 to 1.5>.');
        end
    elseif verb == 'uizoom' then
        local direction = args:lower();
        if direction == 'in' then
            set_scale(cfg.scale + 0.1);
        elseif direction == 'out' then
            set_scale(cfg.scale - 0.1);
        else
            print('[SmartSkillup] Usage: //sms uizoom <in | out>.');
        end
    elseif verb == 'uipos' then
        local x, y = args:match('^(%-?%d+)%s+(%-?%d+)$');
        if x then
            cfg.x, cfg.y = tonumber(x), tonumber(y);
            force_layout = true;
            settings.save();
            print('[SmartSkillup] UI position set to ' .. x .. ', ' .. y .. '.');
        else
            print('[SmartSkillup] UI position is ' .. cfg.x .. ', ' .. cfg.y .. '. Usage: //sms uipos <x> <y>.');
        end
    elseif verb == 'uirebuild' then
        force_layout = true;
        print('[SmartSkillup] UI layout reapplied from the saved position.');
    elseif verb == 'uidefaults' then
        cfg.visible, cfg.scale, cfg.x, cfg.y = DEFAULTS.visible, DEFAULTS.scale, DEFAULTS.x, DEFAULTS.y;
        force_layout = true;
        settings.save();
        print('[SmartSkillup] UI reset to defaults.');
    else
        return false;
    end
    return true;
end

return M;
