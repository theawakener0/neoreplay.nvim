local storage = require('neoreplay.storage')
local M = {}

local buffer_cache = {}

local function get_timestamp()
  return vim.loop.hrtime() / 1e9
end

local function on_lines(_, bufnr, changedtick, firstline, lastline, new_lastline, byte_count)
  if not storage.is_active() then return end
  
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

  -- Update cache
  local next_cache = {}
  for i = 1, firstline do
    table.insert(next_cache, cache[i])
  end
  for _, line in ipairs(after_lines) do
    table.insert(next_cache, line)
  end
  for i = lastline + 1, #cache do
    table.insert(next_cache, cache[i])
  end
  buffer_cache[bufnr] = next_cache

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
  local initial_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  
  storage.start()
  storage.set_initial_state(bufnr, initial_lines)
  buffer_cache[bufnr] = initial_lines

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = on_lines,
    on_detach = function() buffer_cache[bufnr] = nil end
  })
end

function M.stop()
  local bufnr = vim.api.nvim_get_current_buf()
  storage.set_final_state(bufnr, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  storage.stop()
  -- nvim_buf_attach doesn't have an explicit 'detach' function other than returning true from callback
  -- But since we check storage.is_active(), it will effectively stop recording.
end

return M
