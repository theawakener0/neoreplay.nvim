local M = {}

function M.create_replay_window()
  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.8)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(bufnr, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(bufnr, 'readonly', true)

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

  -- Keybindings for controls
  vim.keymap.set('n', 'q', function() vim.api.nvim_win_close(winid, true) end, { buffer = bufnr })
  vim.keymap.set('n', '<Esc>', function() vim.api.nvim_win_close(winid, true) end, { buffer = bufnr })
  vim.keymap.set('n', '<space>', function() require('neoreplay.replay').toggle_pause() end, { buffer = bufnr })
  vim.keymap.set('n', '=', function() require('neoreplay.replay').speed_up() end, { buffer = bufnr })
  vim.keymap.set('n', '-', function() require('neoreplay.replay').speed_down() end, { buffer = bufnr })

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { " [SPACE]: Pause/Play  [=/-]: Speed Up/Down  [q]: Quit " })
  
  return bufnr, winid
end

return M
