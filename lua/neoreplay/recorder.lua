local storage = require('neoreplay.storage')
local utils = require('neoreplay.utils')
local bookmarks = require('neoreplay.bookmarks')
local heatmap = require('neoreplay.heatmap')
local metrics = require('neoreplay.metrics')
local M = {}

local buffer_cache = {}
local attached_buffers = {}

local pending_changes = {}
local coalesce_timers = {}
local COALESCE_DELAY_MS = 50

local function stop_and_close_timer(timer)
  if not timer then return end
  if type(timer) == "number" then
    pcall(vim.fn.timer_stop, timer)
    return
  end
  if timer.stop then
    pcall(timer.stop, timer)
  end
  if timer.close then
    pcall(timer.close, timer)
  end
end

local function get_timestamp()
  return vim.loop.hrtime() / 1e9
end

local function lines_equal(a, b)
  if a == b then return true end
  if not a or not b or #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

local function lines_equal_ignore_whitespace(a, b)
  if not a or not b or #a ~= #b then return false end
  for i = 1, #a do
    local left = (a[i] or ""):gsub("%s+", "")
    local right = (b[i] or ""):gsub("%s+", "")
    if left ~= right then
      return false
    end
  end
  return true
end

local function start_coalesce_timer(bufnr)
  local timer = coalesce_timers[bufnr]
  if not timer then
    timer = vim.loop.new_timer()
    coalesce_timers[bufnr] = timer
  end

  timer:stop()
  timer:start(COALESCE_DELAY_MS, 0, vim.schedule_wrap(function()
    flush_pending_changes(bufnr)
  end))
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
      current.after_lines = next_change.after_lines
      current.new_lastline = next_change.new_lastline
      current.end_time = next_change.timestamp
    else
      table.insert(merged, current)
      current = next_change
    end
  end
  table.insert(merged, current)
  
  -- Store merged events
  for _, change in ipairs(merged) do
    local before_text = table.concat(change.before_lines or {}, "\n")
    local after_text = table.concat(change.after_lines or {}, "\n")
    local meta = utils.get_buffer_meta(bufnr)
    storage.set_buffer_meta(bufnr, meta)
    local ev = {
      timestamp = change.timestamp,
      bufnr = bufnr,  -- Standardized field
      buf = bufnr,    -- Legacy field
      bufname = meta.name,
      filetype = meta.filetype,
      before = before_text,
      after = after_text,
      lnum = change.lnum,
      lastline = change.lastline,
      new_lastline = change.new_lastline,
      edit_type = utils.edit_type(before_text, after_text),
      lines_changed = math.abs((change.new_lastline or change.lastline) - change.lastline),
      kind = 'edit'
    }
    ev.after_lines = change.after_lines -- Temporary for smart_track
    local idx = storage.add_event(ev)
    bookmarks.smart_track(ev, idx)
    heatmap.record(bufnr, change.lnum)
    metrics.record_event(ev)
    ev.after_lines = nil
  end
end

local function on_lines(_, bufnr, changedtick, firstline, lastline, new_lastline, byte_count)
  if not storage.is_active() then 
    attached_buffers[bufnr] = nil
    return true
  end
  
  local cache = buffer_cache[bufnr]
  if not cache then return end

  local before_lines = {}
  local before_start = firstline + 1
  local before_end = lastline
  
  if before_end - before_start < 10 then
    for i = before_start, before_end do
      before_lines[i - before_start + 1] = cache[i] or ""
    end
  else
    for i = before_start, before_end do
      table.insert(before_lines, cache[i] or "")
    end
  end
  local after_lines = vim.api.nvim_buf_get_lines(bufnr, firstline, new_lastline, false)

  local old_count = lastline - firstline
  local new_count = #after_lines
  local diff = new_count - old_count
  
  if diff ~= 0 then
    local cache_size = #cache
    if diff > 0 then
      for i = cache_size, lastline + 1, -1 do
        cache[i + diff] = cache[i]
      end
    else
      table.move(cache, lastline + 1, cache_size, firstline + new_count + 1)
      -- Clear old entries
      for i = cache_size + diff + 1, cache_size do
        cache[i] = nil
      end
    end
  end
  
  for i = 1, #after_lines do
    cache[firstline + i] = after_lines[i]
  end

  if lines_equal(before_lines, after_lines) then return end

  if vim.g.neoreplay_ignore_whitespace then
    if lines_equal_ignore_whitespace(before_lines, after_lines) then
      return
    end
  end

  -- Queue change for coalescing
  if not pending_changes[bufnr] then
    pending_changes[bufnr] = {}
  end
  
  table.insert(pending_changes[bufnr], {
    timestamp = get_timestamp(),
    before_lines = before_lines,
    after_lines = after_lines,
    lnum = firstline + 1,
    lastline = lastline,
    new_lastline = new_lastline,
  })

  start_coalesce_timer(bufnr)
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
      flush_pending_changes(bufnr)
      stop_and_close_timer(coalesce_timers[bufnr])
      coalesce_timers[bufnr] = nil
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
  
  local initial_loc = 0
  for _, bufnr in ipairs(targets) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      initial_loc = initial_loc + vim.api.nvim_buf_line_count(bufnr)
    end
  end
  metrics.start_session(initial_loc)
end

function M.stop()
  for bufnr, _ in pairs(pending_changes) do
    flush_pending_changes(bufnr)
  end
  pending_changes = {}
  
  for bufnr, timer in pairs(coalesce_timers) do
    stop_and_close_timer(timer)
    coalesce_timers[bufnr] = nil
  end
  coalesce_timers = {}
  
  for bufnr, _ in pairs(attached_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      storage.set_final_state(bufnr, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end
  end
  metrics.end_session()
  storage.stop()
  
  -- Clear caches
  buffer_cache = {}
  attached_buffers = {}
end

return M
