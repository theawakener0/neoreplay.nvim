local M = {}

M.controls = " [SPACE] Pause/Play  [=/-] Speed Up/Down  [q] Quit "

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

  vim.api.nvim_set_option_value('winbar', M.controls, { scope = 'local', win = winid })
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

function M.set_progress(winid, progress)
  if not winid or not vim.api.nvim_win_is_valid(winid) then return end
  local text = string.format("%s | %d%%", M.controls, progress)
  vim.api.nvim_set_option_value('winbar', text, { scope = 'local', win = winid })
end

function M.set_annotation(winid, annotation)
  if not winid or not vim.api.nvim_win_is_valid(winid) then return end
  local text = string.format("%s | %s", M.controls, annotation or "")
  vim.api.nvim_set_option_value('winbar', text, { scope = 'local', win = winid })
end

return M
