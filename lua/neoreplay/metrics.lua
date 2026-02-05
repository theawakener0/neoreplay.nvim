local utils = require('neoreplay.utils')
local M = {}

M.data = {
    -- Session timing
    start_time = nil,
    end_time = nil,
    last_event_time = nil,
    
    -- Code metrics
    initial_loc = 0,
    current_loc = 0,
    peak_loc = 0,
    loc_history = {},  -- For sparkline
    
    -- Edit metrics
    total_edits = 0,
    by_type = { insert = 0, delete = 0, replace = 0 },
    by_buffer = {},
    
    -- Time metrics
    active_time = 0,
    pause_time = 0,
    last_activity = nil,
}

local is_active = false
local COMPUTATION_BUDGET_MS = 16  -- 60fps frame budget

function M.start_session(initial_loc)
    M.data.start_time = vim.loop.now()
    M.data.last_activity = M.data.start_time
    M.data.initial_loc = initial_loc or 0
    M.data.current_loc = M.data.initial_loc
    M.data.total_edits = 0
    M.data.by_type = { insert = 0, delete = 0, replace = 0 }
    M.data.by_buffer = {}
    M.data.loc_history = {}
    is_active = true
end

function M.record_event(event)
    if not is_active then return end
    
    local now = vim.loop.now()
    M.data.total_edits = M.data.total_edits + 1
    
    -- Update by type
    if event.edit_type then
        M.data.by_type[event.edit_type] = 
            (M.data.by_type[event.edit_type] or 0) + 1
    end
    
    -- Update by buffer
    local bufnr = event.bufnr or event.buf
    if bufnr then
        M.data.by_buffer[bufnr] = 
            (M.data.by_buffer[bufnr] or 0) + 1
    end
    
    M.data.last_activity = now
    M.data.last_event_time = now
    
    -- Update LOC
    if event.before_lines or event.after_lines then
      local before_count = event.before_lines and #event.before_lines or 0
      local after_count = event.after_lines and #event.after_lines or 0
      M.data.current_loc = M.data.current_loc - before_count + after_count
      M.data.peak_loc = math.max(M.data.peak_loc, M.data.current_loc)
    end
    
    -- Sample LOC for sparkline
    if not M.data.loc_history[1] or 
       (now - M.data.loc_history[#M.data.loc_history].time) > 2000 then
        table.insert(M.data.loc_history, {
            time = now,
            loc = M.data.current_loc,
        })
    end
end

function M.get_summary()
    local summary = {
        duration = 0,
        total_edits = M.data.total_edits,
        net_loc_change = M.data.current_loc - M.data.initial_loc,
        edits_per_minute = 0,
        by_type = M.data.by_type,
        current_loc = M.data.current_loc,
        peak_loc = M.data.peak_loc,
        loc_history = M.data.loc_history,
    }
    
    if M.data.start_time then
        local end_time = M.data.end_time or vim.loop.now()
        summary.duration = (end_time - M.data.start_time) / 1000  -- seconds
        if summary.duration > 0 then
          summary.edits_per_minute = (M.data.total_edits / summary.duration) * 60
        end
    end
    
    return summary
end

function M.end_session()
    M.data.end_time = vim.loop.now()
    is_active = false
end

---Backward compatibility for batch calculation
function M.calculate(session)
  M.start_session(0)
  for _, event in ipairs(session.events) do
    M.record_event(event)
  end
  M.end_session()
  return M.get_summary()
end

return M
