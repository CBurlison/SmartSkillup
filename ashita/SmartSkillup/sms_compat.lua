-- Luau-style helpers used by the Windower logic files (T{}, S{}, :schedule, :wmatch), implemented for Ashita.

local M = {};

-- Table with find/contains helpers, matching the Windower T{} behaviour.
local T_mt = {};
T_mt.__index = T_mt;
function T_mt:contains(value)
    for _, v in pairs(self) do
        if v == value then return true; end
    end
    return false;
end
function T_mt:find(value_or_fn)
    for k, v in pairs(self) do
        if type(value_or_fn) == 'function' then
            if value_or_fn(v) then return k; end
        elseif v == value_or_fn then
            return k;
        end
    end
    return nil;
end
function T_mt:insert(value)
    table.insert(self, value);
end
function T_mt:delete(value)
    local k = self:find(value);
    if k ~= nil then
        if type(k) == 'number' then table.remove(self, k); else self[k] = nil; end
    end
end
function T_mt:length()
    local n = 0;
    for _ in pairs(self) do n = n + 1; end
    return n;
end
function M.T(t)
    return setmetatable(t or {}, T_mt);
end

-- Set type: values are keys, so contains is a direct lookup.
local S_mt = {};
S_mt.__index = S_mt;
function S_mt:contains(value)
    return rawget(self, value) ~= nil;
end
function M.S(list)
    local set = setmetatable({}, S_mt);
    for _, v in ipairs(list or {}) do
        rawset(set, v, true);
    end
    return set;
end

-- Delayed work, driven by the d3d_present frame tick.
local pending = {};

local function schedule(fn, delay, ...)
    local args = { ... };
    local entry = { co = coroutine.create(fn), at = os.clock() + (delay or 0), args = args, cancelled = false };
    table.insert(pending, entry);
    return entry;
end
M.schedule = schedule;

function M.cancel(entry)
    if entry then entry.cancelled = true; end
end

function M.pending_count()
    return #pending;
end

-- Lets 'fn:schedule(delay, ...)' work on functions, as Windower's luau does.
debug.setmetatable(function() end, { __index = {
    schedule = function(fn, delay, ...) return schedule(fn, delay, ...); end,
} });

function M.tick()
    local now = os.clock();
    local i = 1;
    while i <= #pending do
        local entry = pending[i];
        if entry.cancelled then
            table.remove(pending, i);
        elseif now >= entry.at then
            table.remove(pending, i);
            local ok, err = coroutine.resume(entry.co, unpack(entry.args));
            if not ok then print('[SmartSkillup] scheduled task failed: ' .. tostring(err)); end
        else
            i = i + 1;
        end
    end
end

-- Windower's wmatch: '|' separates alternatives, '*' matches any run of characters. Case-insensitive.
function M.wmatch(s, patterns)
    s = tostring(s):lower();
    for alt in patterns:gmatch('[^|]+') do
        local lua_pat = '^' .. alt:lower():gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0'):gsub('%*', '.*') .. '$';
        if s:match(lua_pat) then return true; end
    end
    return false;
end

-- Adds string:wmatch and the function:schedule helper, matching the Windower environment.
function M.install_globals()
    local mt = getmetatable('');
    local original_index = mt.__index;
    local wmatch_fn = function(s, patterns) return M.wmatch(s, patterns); end;
    -- Ashita's string metatable __index may be a function rather than the string table, so wrap whichever it is.
    mt.__index = function(s, k)
        if k == 'wmatch' then return wmatch_fn; end
        if type(original_index) == 'table' then return original_index[k]; end
        return original_index(s, k);
    end;
    T = M.T;
    S = M.S;
    coroutine.schedule = schedule;
    -- LuaJIT has no coroutine.close; the Windower logic calls pcall(coroutine.close, handle) to cancel timers.
    local original_close = coroutine.close;
    coroutine.close = function(handle, ...)
        if type(handle) == 'table' then
            M.cancel(handle);
            return true;
        end
        if original_close then return original_close(handle, ...); end
    end;
end

return M;
