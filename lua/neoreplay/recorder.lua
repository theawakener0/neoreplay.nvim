local storage = require('neoreplay.storage')
local utils = require('neoreplay.utils')
local M = {}

local buffer_cache = {}
local attached_buffers = {}

-- Change coalescing: batch rapid edits
local pending_changes = {}
local coalesce_timers = {}
local COALESCE_DELAY_MS = 50  -- Batch edits within 50ms

local function get_timestamp()
  return vim.loop.hrtime() / 1e9
end

local function flush_pending_changes(bufnr)
  if not pending_changes[bufnr] or #pending_changes[bufnr] == 0 then
    pending_changes[bufnr] = nil
    return
  end
  
  local changes = pending_changes[bufnr]
  pending_changes[bufnr] = nil
  
  -- Merge consecutive changes on same line range
  local merged = {}
  local current = changes[1]
  
  for i = 2, #changes do
    local next_change = changes[i]
    if next_change.lnum == current.lnum and 
       next_change.lastline == current.lastline and
       (next_change.timestamp - current.timestamp) < 0.1 then
      -- Merge: just update the after state
      current.after = next_change.after
      current.after_lines = next_change.after_lines
      current.end_time = next_change.timestamp
    else
      table.insert(merged, current)
      current = next_change
    end
  end
  table.insert(merged, current)
  
  -- Store merged events
  for _, change in ipairs(merged) do
    local meta = utils.get_buffer_meta(bufnr)
    storage.set_buffer_meta(bufnr, meta)
    storage.add_event({
      timestamp = change.timestamp,
      buf = bufnr,
      bufname = meta.name,
      filetype = meta.filetype,
      before = change.before,
      after = change.after,
      lnum = change.lnum,
      lastline = change.lastline,
      new_lastline = change.new_lastline,
      edit_type = utils.edit_type(change.before or '', change.after or ''),
      lines_changed = math.abs((change.new_lastline or change.lastline) - change.lastline),
      kind = 'edit'
    })
  end
end

local function on_lines(_, bufnr, changedtick, firstline, lastline, new_lastline, byte_count)
  if not storage.is_active() then 
    attached_buffers[bufnr] = nil
    return true -- Detach the handler
  end
  
  local cache = buffer_cache[bufnr]
  if not cache then return end

  -- Get the 'before' text from our cache
  local before_lines = {}
  local before_start = firstline + 1
  local before_end = lastline
  
  -- Optimize: use direct indexing for small ranges
  if before_end - before_start < 10 then
    for i = before_start, before_end do
      before_lines[i - before_start + 1] = cache[i] or ""
    end
  else
    for i = before_start, before_end do
      table.insert(before_lines, cache[i] or "")
    end
  end
  local before_text = table.concat(before_lines, "\n")

  -- Get the 'after' text from the actual buffer
  local after_lines = vim.api.nvim_buf_get_lines(bufnr, firstline, new_lastline, false)
  local after_text = table.concat(after_lines, "\n")

  -- Update cache efficiently
  local old_count = lastline - firstline
  local new_count = #after_lines
  local diff = new_count - old_count
  
  if diff ~= 0 then
    -- Pre-calculate new size and use table.move
    local cache_size = #cache
    if diff > 0 then
      -- Growing: move existing lines to make room
      for i = cache_size, lastline + 1, -1 do
        cache[i + diff] = cache[i]
      end
    else
      -- Shrinking: compact the table
      table.move(cache, lastline + 1, cache_size, firstline + new_count + 1)
      -- Clear old entries
      for i = cache_size + diff + 1, cache_size do
        cache[i] = nil
      end
    end
  end
  
  -- Update cached lines
  for i = 1, #after_lines do
    cache[firstline + i] = after_lines[i]
  end

  -- Skip if no delta (sometimes happens with metadata changes)
  if before_text == after_text then return end

  -- Configurable: ignore whitespace-only changes
  if vim.g.neoreplay_ignore_whitespace then
    if before_text:gsub("%s+", "") == after_text:gsub("%s+", "") then
      return
    end
  end

  -- Queue change for coalescing
  if not pending_changes[bufnr] then
    pending_changes[bufnr] = {}
  end
  
  table.insert(pending_changes[bufnr], {
    timestamp = get_timestamp(),
    before = before_text,
    after = after_text,
    after_lines = after_lines,
    lnum = firstline + 1,
    lastline = lastline,
    new_lastline = new_lastline,
  })
  
  -- Reset and restart coalesce timer
  if coalesce_timers[bufnr] then
    pcall(vim.fn.timer_stop, coalesce_timers[bufnr])
  end
  
  coalesce_timers[bufnr] = vim.defer_fn(function()
    flush_pending_changes(bufnr)
    coalesce_timers[bufnr] = nil
  end, COALESCE_DELAY_MS)
end

local function attach_buffer(bufnr)
  if attached_buffers[bufnr] then return end

  local initial_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  
  -- Pre-allocate cache with estimated capacity (current + 50%)
  local initial_copy = {}
  local cache = {}
  local estimated_capacity = math.floor(#initial_lines * 1.5) + 100
  
  for i = 1, #initial_lines do
    initial_copy[i] = initial_lines[i]
    cache[i] = initial_lines[i]
  end
  
  -- Pre-fill remaining slots with nil to allocate memory
  for i = #initial_lines + 1, estimated_capacity do
    cache[i] = nil
  end

  storage.set_initial_state(bufnr, initial_copy)
  storage.set_buffer_meta(bufnr, utils.get_buffer_meta(bufnr))
  buffer_cache[bufnr] = cache

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = on_lines,
    on_detach = function()
      -- Flush any pending changes before detaching
      flush_pending_changes(bufnr)
      buffer_cache[bufnr] = nil
      attached_buffers[bufnr] = nil
    end
  })
  attached_buffers[bufnr] = true
end

function M.start(opts)
  opts = opts or {}
  if not storage.is_active() then
    storage.start()
  end

  local targets = {}
  if opts.bufnrs and #opts.bufnrs > 0 then
    targets = opts.bufnrs
  elseif opts.all_buffers or vim.g.neoreplay_record_all_buffers then
    targets = utils.list_recordable_buffers()
  else
    targets = { vim.api.nvim_get_current_buf() }
  end

  for _, bufnr in ipairs(targets) do
    if utils.is_real_buffer(bufnr) then
      attach_buffer(bufnr)
    end
  end

  storage.set_metadata({
    recorded_buffers = targets,
    started_at = vim.loop.hrtime() / 1e9,
  })
end

function M.stop()
  -- Flush all pending changes
  for bufnr, _ in pairs(pending_changes) do
    flush_pending_changes(bufnr)
  end
  pending_changes = {}
  
  for bufnr, timer in pairs(coalesce_timers) do
    pcall(vim.fn.timer_stop, timer)
  end
  coalesce_timers = {}
  
  for bufnr, _ in pairs(attached_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      storage.set_final_state(bufnr, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end
  end
  storage.stop()
  
  -- Clear caches
  buffer_cache = {}
  attached_buffers = {}
end

return M
