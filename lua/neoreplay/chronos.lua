local storage = require('neoreplay.storage')
local utils = require('neoreplay.utils')

local M = {}

-- Optimized sequence collection without full flattening
local function collect_sequences_streaming(entries, callback)
  if not entries then return end
  
  for _, entry in ipairs(entries) do
    local cur = entry
    while cur do
      if cur.seq then
        callback(cur)
      end
      -- Process alternatives inline instead of recursive flattening
      if cur.alt then
        for _, alt_entry in ipairs(cur.alt) do
          local alt_cur = alt_entry
          while alt_cur do
            if alt_cur.seq then
              callback(alt_cur)
            end
            alt_cur = alt_cur.next
          end
        end
      end
      cur = cur.next
    end
  end
end

local function clamp(val, min_val, max_val)
  if val < min_val then return min_val end
  if val > max_val then return max_val end
  return val
end

-- Efficient cache copy using pre-allocated buffer
local function copy_cache_efficient(tbl, capacity)
  local copy = {}
  for i, v in ipairs(tbl) do
    copy[i] = v
  end
  return copy
end

function M.excavate(bufnr, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  opts = opts or {}
  if storage.is_active() and not opts.force then
    vim.notify("NeoReplay Chronos: Recording is active. Stop recording or pass force=true.", vim.log.levels.WARN)
    return nil
  end
  
  local ut = vim.fn.undotree()
  if not ut.entries or #ut.entries == 0 then
    vim.notify("NeoReplay Chronos: No undo history found.", vim.log.levels.WARN)
    return nil
  end

  if not vim.o.undofile then
    vim.notify("NeoReplay Chronos: undofile is disabled. History may be truncated; consider setting vim.opt.undofile = true.", vim.log.levels.WARN)
  end

  -- Get current state before we start
  local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local initial_state = copy_cache_efficient(current_lines)

  -- Collect sequences without flattening - use streaming approach
  local seq_map = { [0] = true }
  local seq_info = {}
  local branch_points = {}
  
  collect_sequences_streaming(ut.entries, function(entry)
    if entry.seq then
      seq_map[entry.seq] = true
      local t = entry.time or 0
      if not seq_info[entry.seq] then
        seq_info[entry.seq] = { seq = entry.seq, time = t }
      elseif seq_info[entry.seq].time == 0 and t ~= 0 then
        seq_info[entry.seq].time = t
      end
    end
    if entry.alt then
      branch_points[entry.seq] = true
    end
  end)

  -- Build sorted sequence list
  local seq_list = {}
  for seq in pairs(seq_map) do
    local info = seq_info[seq] or { seq = seq, time = 0 }
    table.insert(seq_list, info)
  end

  table.sort(seq_list, function(a, b)
    if a.time == b.time then
      return a.seq < b.seq
    end
    if a.time == 0 then return false end
    if b.time == 0 then return true end
    return a.time < b.time
  end)

  -- Calculate timestamps with smoothing
  local min_step = opts.smooth_min_step or 0.03
  local max_step = opts.smooth_max_step or 1.25
  local per_event_step = opts.smooth_event_step or 0.015

  local seq_timestamps = {}
  local base_time = 1000.0
  local last_time = nil
  for _, item in ipairs(seq_list) do
    local raw_delta = 0
    if last_time and item.time ~= 0 then
      raw_delta = item.time - last_time
    end
    local delta = (item.time == 0) and min_step or clamp(raw_delta, min_step, max_step)
    base_time = base_time + delta
    seq_timestamps[item.seq] = base_time
    if item.time ~= 0 then
      last_time = item.time
    end
  end

  -- Use the current buffer with a marker to track state
  -- Instead of scratch buffer + full copy, we use undo commands directly
  local raw_events = {}
  local cache = copy_cache_efficient(current_lines)
  local current_timestamp = 1000.0
  local pending_timestamp = nil
  local intra_step = 0

  -- Store original undo position
  local original_seq = vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.undotree().seq_cur or 0
  end)

  -- Attach listener to capture changes
  local detach_fn = nil
  local listener_attached = false
  
  -- Pre-allocate event table capacity
  local estimated_events = #seq_list * 2  -- Rough estimate
  
  local function capture_changes()
    detach_fn = vim.api.nvim_buf_attach(bufnr, false, {
      on_lines = function(_, _, _, first, last, new_last)
        if not listener_attached then return end
        
        local before_lines = {}
        local before_start = first + 1
        local before_end = last
        
        -- Fast path for small ranges
        if before_end - before_start < 5 then
          for i = before_start, before_end do
            before_lines[i - before_start + 1] = cache[i] or ""
          end
        else
          for i = before_start, before_end do
            table.insert(before_lines, cache[i] or "")
          end
        end
        local before_text = table.concat(before_lines, "\n")

        -- Update cache efficiently
        local scratch_lines = vim.api.nvim_buf_get_lines(bufnr, first, new_last, false)
        local diff = #scratch_lines - (last - first)
        if diff ~= 0 then
          table.move(cache, last + 1, #cache, first + #scratch_lines + 1)
          if diff < 0 then
            for i = #cache + diff + 1, #cache do cache[i] = nil end
          end
        end
        for i, line in ipairs(scratch_lines) do
          cache[first + i] = line
        end

        local ts = (pending_timestamp or current_timestamp) + intra_step
        table.insert(raw_events, {
          timestamp = ts,
          buf = bufnr,
          before = before_text,
          after = table.concat(scratch_lines, "\n"),
          lnum = first + 1,
          lastline = last,
          new_lastline = new_last
        })
        intra_step = intra_step + per_event_step
        current_timestamp = ts
      end
    })
    listener_attached = true
  end

  -- Capture changes during undo traversal
  local success, exc_err = pcall(function()
    capture_changes()
    
    -- Traverse undo history
    vim.api.nvim_buf_call(bufnr, function()
      -- Go to beginning
      vim.cmd('noautocmd undo 0')
      
      for _, info in ipairs(seq_list) do
        local seq = info.seq
        if seq > 0 then
          if branch_points[seq] then
            local seg_ts = current_timestamp + min_step
            table.insert(raw_events, {
              timestamp = seg_ts,
              buf = bufnr,
              kind = 'segment',
              label = 'Branch point @' .. tostring(seq),
              lnum = 1,
              lastline = 0,
              new_lastline = 0,
            })
            current_timestamp = seg_ts
          end
          pending_timestamp = seq_timestamps[seq] or (current_timestamp + min_step)
          intra_step = 0
          vim.cmd('noautocmd undo ' .. seq)
        end
      end
      
      -- Return to original position
      vim.cmd('noautocmd undo ' .. original_seq)
    end)
    
    -- Get final state
    cache = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end)

  -- Detach listener
  listener_attached = false
  if detach_fn then
    pcall(detach_fn)
  end

  if not success then
    vim.notify("NeoReplay Chronos: Excavation error: " .. tostring(exc_err), vim.log.levels.ERROR)
    return nil
  end

  -- Persist into storage
  if not storage.is_active() then
    storage.start()
  end
  
  storage.set_initial_state(bufnr, initial_state)
  local buffer_meta = utils.get_buffer_meta(bufnr)
  storage.set_buffer_meta(bufnr, buffer_meta)

  for _, ev in ipairs(raw_events) do
    if ev.kind ~= 'segment' then
      ev.bufname = buffer_meta.name
      ev.filetype = buffer_meta.filetype
      ev.edit_type = utils.edit_type(ev.before or '', ev.after or '')
      ev.lines_changed = math.abs((ev.new_lastline or 0) - (ev.lastline or 0))
      ev.kind = ev.kind or 'edit'
    end
    storage.add_event(ev)
  end

  local final_state = copy_cache_efficient(cache)
  storage.set_final_state(bufnr, final_state)

  local index = { by_buf = { [bufnr] = #raw_events }, total_events = #raw_events }
  
  return {
    initial_state = initial_state,
    raw_events = raw_events,
    final_state = final_state,
    buffer_meta = buffer_meta,
    index = index,
    metadata = { excavated = true }
  }
end

return M
