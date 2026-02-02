local storage = require('neoreplay.storage')
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

  storage.add_event({
    timestamp = get_timestamp(),
    buf = bufnr,
    before = before_text,
    after = after_text,
    lnum = firstline + 1,
    lastline = lastline,
    new_lastline = new_lastline
  })
end

function M.start()
  local bufnr = vim.api.nvim_get_current_buf()
  if attached_buffers[bufnr] then return end

  local initial_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  
  storage.start()
  storage.set_initial_state(bufnr, initial_lines)
  buffer_cache[bufnr] = initial_lines

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = on_lines,
    on_detach = function() 
      buffer_cache[bufnr] = nil 
      attached_buffers[bufnr] = nil
    end
  })
  attached_buffers[bufnr] = true
end

function M.stop()
  local bufnr = vim.api.nvim_get_current_buf()
  storage.set_final_state(bufnr, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  storage.stop()
end

return M
