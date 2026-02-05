local metrics = require('neoreplay.metrics')
local storage = require('neoreplay.storage')
local timers = require('neoreplay.utils.timers')
local M = {}

M.winid = nil
M.bufnr = nil
M.timer_id = nil

local function create_sparkline(values, width)
  if #values == 0 then return string.rep(" ", width) end
  local chars = { " ", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
  local min_val = values[1]
  local max_val = values[1]
  for _, v in ipairs(values) do
    if v < min_val then min_val = v end
    if v > max_val then max_val = v end
  end

  local range = max_val - min_val
  if range == 0 then range = 1 end

  local result = ""
  local step = #values / width
  for i = 1, width do
    local idx = math.floor((i - 1) * step) + 1
    local val = values[idx] or values[#values]
    local char_idx = math.floor(((val - min_val) / range) * (#chars - 1)) + 1
    result = result .. chars[char_idx]
  end
  return result
end

function M.update()
  if not M.winid or not vim.api.nvim_win_is_valid(M.winid) then
    if M.timer_id then
      timers.stop_timer(M.timer_id)
      M.timer_id = nil
    end
    return
  end

  local data = metrics.get_summary()
  local width = vim.api.nvim_win_get_width(M.winid)
  local lines = {}
  
  table.insert(lines, " SESSION SUMMARY")
  table.insert(lines, string.rep("─", width - 2))
  table.insert(lines, string.format(" Duration:    %.1fs", data.duration or 0))
  table.insert(lines, string.format(" Total Edits: %d", data.total_edits or 0))
  local change = data.net_loc_change or 0
  table.insert(lines, string.format(" LOC Change:  %+d (Peak: %d)", change, data.peak_loc or 0))
  table.insert(lines, string.format(" Efficiency:  %.1f edits/min", data.edits_per_minute or 0))
  table.insert(lines, "")
  
  table.insert(lines, " EDIT BREAKDOWN")
  table.insert(lines, string.rep("─", width - 2))
  local bt = data.by_type or {}
  local insertions = bt.insert or 0
  local deletions = bt.delete or 0
  local modifications = bt.replace or 0
  local total = insertions + deletions + modifications
  
  if total > 0 then
    local i_pct = math.floor((insertions / total) * 100)
    local d_pct = math.floor((deletions / total) * 100)
    local m_pct = 100 - i_pct - d_pct
    table.insert(lines, string.format(" Insertions:  %d (%d%%)", insertions, i_pct))
    table.insert(lines, string.format(" Deletions:   %d (%d%%)", deletions, d_pct))
    table.insert(lines, string.format(" Mods:        %d (%d%%)", modifications, m_pct))
  else
    table.insert(lines, " No edits recorded.")
  end
  table.insert(lines, "")

  table.insert(lines, " ACTIVITY (LOC OVER TIME)")
  table.insert(lines, string.rep("─", width - 2))
  local loc_vals = {}
  for _, entry in ipairs(data.loc_history or {}) do
    table.insert(loc_vals, entry.loc)
  end
  table.insert(lines, " " .. create_sparkline(loc_vals, width - 4))
  table.insert(lines, "")
  
  table.insert(lines, " Press 'q' to close")

  vim.api.nvim_buf_set_option(M.bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(M.bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.bufnr, 'modifiable', false)
end

function M.open()
  if M.winid and vim.api.nvim_win_is_valid(M.winid) then
    vim.api.nvim_set_current_win(M.winid)
    return
  end

  M.bufnr = vim.api.nvim_create_buf(false, true)
  local width = 50
  local height = 18
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  M.winid = vim.api.nvim_open_win(M.bufnr, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = 'rounded',
    title = ' NeoReplay Dashboard ',
    title_pos = 'center',
  })

  vim.api.nvim_buf_set_option(M.bufnr, 'bufhidden', 'wipe')
  
  -- Set keymaps
  vim.keymap.set('n', 'q', function() M.close() end, { buffer = M.bufnr, silent = true })
  vim.keymap.set('n', '<Esc>', function() M.close() end, { buffer = M.bufnr, silent = true })

  M.update()
  
  -- Start auto-refresh
  M.timer_id = timers.interval(vim.schedule_wrap(function()
    M.update()
  end), 250) -- Better responsiveness
end

function M.close()
  if M.timer_id then
    timers.stop_timer(M.timer_id)
    M.timer_id = nil
  end
  if M.winid and vim.api.nvim_win_is_valid(M.winid) then
    vim.api.nvim_win_close(M.winid, true)
  end
  M.winid = nil
  M.bufnr = nil
end

function M.toggle()
  if M.winid and vim.api.nvim_win_is_valid(M.winid) then
    M.close()
  else
    M.open()
  end
end

return M
