local storage = require('neoreplay.storage')
local utils = require('neoreplay.utils')
local M = {}

local buffer_cache = {}
local attached_buffers = {}

local function get_timestamp()
  return vim.loop.hrtime() / 1e9
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
  for i = firstline + 1, lastline do
    table.insert(before_lines, cache[i] or "")
  end
  local before_text = table.concat(before_lines, "\n")

  -- Get the 'after' text from the actual buffer
  local after_lines = vim.api.nvim_buf_get_lines(bufnr, firstline, new_lastline, false)
  local after_text = table.concat(after_lines, "\n")

  -- Update cache efficiently using table.move
  local diff = #after_lines - (lastline - firstline)
  if diff ~= 0 then
    table.move(cache, lastline + 1, #cache, firstline + #after_lines + 1)
    if diff < 0 then
      for i = #cache + diff + 1, #cache do
        cache[i] = nil
      end
    end
  end
  for i, line in ipairs(after_lines) do
    cache[firstline + i] = line
  end

  -- Skip if no delta (sometimes happens with metadata changes)
  if before_text == after_text then return end

  -- Configurable: ignore whitespace-only changes
  if vim.g.neoreplay_ignore_whitespace then
    if before_text:gsub("%s+", "") == after_text:gsub("%s+", "") then
      return
    end
  end

  local meta = utils.get_buffer_meta(bufnr)
  storage.set_buffer_meta(bufnr, meta)
  storage.add_event({
    timestamp = get_timestamp(),
    buf = bufnr,
    bufname = meta.name,
    filetype = meta.filetype,
    before = before_text,
    after = after_text,
    lnum = firstline + 1,
    lastline = lastline,
    new_lastline = new_lastline,
    edit_type = utils.edit_type(before_text, after_text),
    lines_changed = math.abs(new_lastline - lastline),
    kind = 'edit'
  })
end

local function attach_buffer(bufnr)
  if attached_buffers[bufnr] then return end

  local initial_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- Create copies to prevent reference sharing issues
  local initial_copy = {}
  for i, line in ipairs(initial_lines) do initial_copy[i] = line end
  local cache_copy = {}
  for i, line in ipairs(initial_lines) do cache_copy[i] = line end

  storage.set_initial_state(bufnr, initial_copy)
  storage.set_buffer_meta(bufnr, utils.get_buffer_meta(bufnr))
  buffer_cache[bufnr] = cache_copy

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = on_lines,
    on_detach = function()
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
  for bufnr, _ in pairs(attached_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      storage.set_final_state(bufnr, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end
  end
  storage.stop()
end

return M
