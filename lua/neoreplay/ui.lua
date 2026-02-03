local M = {}

M.controls = " [SPACE] Pause/Play  [=/-] Speed Up/Down  [q] Quit "

-- Debounce state
local debounce_timers = {}
local pending_annotations = {}

local annotation_ns = vim.api.nvim_create_namespace('neoreplay_ui')

local function stop_timer(timer)
  if not timer then return end
  if type(timer) == "number" then
    pcall(vim.fn.timer_stop, timer)
  elseif timer.stop then
    pcall(timer.stop, timer)
    pcall(timer.close, timer)
  end
end

local function escape_winbar(text)
  return tostring(text):gsub("%%", "%%%%")
end

local function setup_replay_buffer(bufnr, original_bufnr)
  vim.api.nvim_buf_set_option(bufnr, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(bufnr, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(bufnr, 'swapfile', false)
  vim.api.nvim_buf_set_option(bufnr, 'undolevels', -1)
  vim.api.nvim_buf_set_option(bufnr, 'readonly', true)
  vim.api.nvim_buf_set_option(bufnr, 'modifiable', true)

  if original_bufnr and vim.api.nvim_buf_is_valid(original_bufnr) then
    local ft = vim.api.nvim_buf_get_option(original_bufnr, 'filetype')
    vim.api.nvim_buf_set_option(bufnr, 'filetype', ft)
  end

  local controls = vim.g.neoreplay_controls or {}
  local quit = controls.quit or 'q'
  local quit_alt = controls.quit_alt or '<Esc>'
  local pause = controls.pause or '<space>'
  local faster = controls.faster or '='
  local slower = controls.slower or '-'

  vim.keymap.set('n', quit, function() require('neoreplay.replay').stop_playback() end, { buffer = bufnr })
  vim.keymap.set('n', quit_alt, function() require('neoreplay.replay').stop_playback() end, { buffer = bufnr })
  vim.keymap.set('n', pause, function() require('neoreplay.replay').toggle_pause() end, { buffer = bufnr })
  vim.keymap.set('n', faster, function() require('neoreplay.replay').speed_up() end, { buffer = bufnr })
  vim.keymap.set('n', slower, function() require('neoreplay.replay').speed_down() end, { buffer = bufnr })
end

function M.create_replay_window(original_bufnr)
  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.8)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local bufnr = vim.api.nvim_create_buf(false, true)
  setup_replay_buffer(bufnr, original_bufnr)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = 'rounded',
    title = ' NeoReplay ',
    title_pos = 'center',
  })

    vim.api.nvim_set_option_value('winbar', escape_winbar(M.controls), { scope = 'local', win = winid })
  return bufnr, winid
end

function M.create_scene_windows(original_bufnrs, focus_bufnr)
  local bufnr_map = {}
  local win_map = {}

  -- Open a new tabpage for a clean scene
  vim.cmd('tabnew')

  local focus_buf = focus_bufnr or original_bufnrs[1]
  for i, original in ipairs(original_bufnrs) do
    if i > 1 then
      vim.cmd('vsplit')
    end

    local bufnr = vim.api.nvim_create_buf(false, true)
    setup_replay_buffer(bufnr, original)
    local winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.api.nvim_set_option_value('winbar', M.controls, { scope = 'local', win = winid })

    bufnr_map[original] = bufnr
    win_map[original] = winid
  end

  -- Focus primary track
  if focus_buf and win_map[focus_buf] then
    pcall(vim.api.nvim_set_current_win, win_map[focus_buf])
  end

  return bufnr_map, win_map
end

-- Immediate progress update (use sparingly)
function M.set_progress(winid, progress)
  if not winid or not vim.api.nvim_win_is_valid(winid) then return end
    local text = string.format("%s | %d%%", M.controls, progress)
    vim.api.nvim_set_option_value('winbar', escape_winbar(text), { scope = 'local', win = winid })
end

-- Immediate annotation update (use sparingly)
function M.set_annotation(winid, annotation)
  if not winid or not vim.api.nvim_win_is_valid(winid) then return end
    local text = string.format("%s | %s", M.controls, annotation or "")
    vim.api.nvim_set_option_value('winbar', escape_winbar(text), { scope = 'local', win = winid })
end

-- Debounced annotation update (preferred for high-frequency updates)
function M.set_annotation_debounced(winid, annotation, delay_ms)
  delay_ms = delay_ms or 100
  
  if not winid then return end
  
  -- Store pending annotation
  pending_annotations[winid] = annotation
  
  -- Cancel existing timer
  if debounce_timers[winid] then
    stop_timer(debounce_timers[winid])
  end
  
  -- Set new timer
  debounce_timers[winid] = vim.defer_fn(function()
    if vim.api.nvim_win_is_valid(winid) then
        local text = string.format("%s | %s", M.controls, pending_annotations[winid] or "")
        vim.api.nvim_set_option_value('winbar', escape_winbar(text), { scope = 'local', win = winid })
    end
    debounce_timers[winid] = nil
    pending_annotations[winid] = nil
  end, delay_ms)
end

-- Set virtual text annotation (more performant alternative to winbar)
function M.set_virtual_annotation(bufnr, annotation, highlight)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  
  highlight = highlight or 'Comment'
  
  -- Clear existing virtual text
  vim.api.nvim_buf_clear_namespace(bufnr, annotation_ns, 0, -1)
  
  -- Set virtual text on first line
  vim.api.nvim_buf_set_virtual_text(bufnr, annotation_ns, 0, {
    { annotation, highlight }
  }, {})
end

-- Cleanup function
function M.cleanup()
  for winid, timer in pairs(debounce_timers) do
    stop_timer(timer)
  end
  debounce_timers = {}
  pending_annotations = {}
end

return M
