if vim.g.loaded_neoreplay then
  return
end
vim.g.loaded_neoreplay = 1

local neoreplay = require('neoreplay')

vim.api.nvim_create_user_command('NeoReplayStart', neoreplay.start, {})
vim.api.nvim_create_user_command('NeoReplayStop', neoreplay.stop, {})
vim.api.nvim_create_user_command('NeoReplayPlay', neoreplay.play, {})
vim.api.nvim_create_user_command('NeoReplayExport', neoreplay.export, {})
