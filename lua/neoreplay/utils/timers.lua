local M = {}

-- Registry of active timers for cleanup
local active_timers = {}
local timer_id_counter = 0

-- Safely stop and close a timer
function M.stop_timer(timer_id)
    if not timer_id then
        return false
    end
    
    local timer = active_timers[timer_id]
    if not timer then
        return false
    end
    
    -- Handle different timer types
    if type(timer) == "number" then
        -- vim.defer_fn returns a number (timer ID)
        pcall(vim.fn.timer_stop, timer)
    elseif type(timer) == "table" then
        -- vim.loop timer object
        if timer.stop then
            pcall(timer.stop, timer)
        end
        if timer.close then
            pcall(timer.close, timer)
        end
    end
    
    active_timers[timer_id] = nil
    return true
end

-- Create a timer (one-shot or recurring)
function M.create_timer(callback, delay_ms, recurring)
    timer_id_counter = timer_id_counter + 1
    local timer_id = timer_id_counter
    
    if not recurring then
        local timer = vim.defer_fn(function()
            active_timers[timer_id] = nil
            callback()
        end, delay_ms)
        active_timers[timer_id] = timer
    else
        local timer = vim.loop.new_timer()
        if not timer then return nil end
        
        timer:start(delay_ms, delay_ms, vim.schedule_wrap(function()
            callback()
        end))
        active_timers[timer_id] = timer
    end
    
    return timer_id
end

-- Create a one-shot timer (backward compatibility)
function M.defer(callback, delay_ms)
    return M.create_timer(callback, delay_ms, false)
end

-- Create a recurring timer (backward compatibility)
function M.interval(callback, delay_ms)
    return M.create_timer(callback, delay_ms, true)
end

-- Stop all active timers
function M.stop_all()
    for timer_id, _ in pairs(active_timers) do
        M.stop_timer(timer_id)
    end
    active_timers = {}
end

-- Get count of active timers
function M.count()
    local count = 0
    for _ in pairs(active_timers) do
        count = count + 1
    end
    return count
end

return M