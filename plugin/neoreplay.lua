if vim.g.loaded_neoreplay then
  return
end
vim.g.loaded_neoreplay = 1

local neoreplay = require('neoreplay')

local function parse_args(args)
  local opts = {}
  for _, arg in ipairs(args) do
    local k, v = arg:match("([^=]+)=(.+)")
    if k and v then
      if v == "true" then
        opts[k] = true
      elseif v == "false" then
        opts[k] = false
      elseif tonumber(v) then
        opts[k] = tonumber(v)
      else
        opts[k] = v
      end
    end
  end
  return opts
end

vim.api.nvim_create_user_command('NeoReplayStart', function(opts)
  neoreplay.start(parse_args(opts.fargs))
end, { nargs = '*' })
vim.api.nvim_create_user_command('NeoReplayStop', neoreplay.stop, {})
vim.api.nvim_create_user_command('NeoReplayPlay', neoreplay.play, {})
vim.api.nvim_create_user_command('NeoReplayClear', neoreplay.clear, {})
vim.api.nvim_create_user_command('NeoReplayFlex', neoreplay.flex, {})
vim.api.nvim_create_user_command('NeoReplayExport', neoreplay.export, {})
vim.api.nvim_create_user_command('NeoReplayExportVHS', neoreplay.export_vhs, {})

vim.api.nvim_create_user_command('NeoReplayExportGIF', function(opts)
  neoreplay.export_gif(parse_args(opts.fargs))
end, { nargs = '*' })

vim.api.nvim_create_user_command('NeoReplayExportMP4', function(opts)
  neoreplay.export_mp4(parse_args(opts.fargs))
end, { nargs = '*' })

vim.api.nvim_create_user_command('NeoReplayExportFrames', function(opts)
  neoreplay.export_frames(parse_args(opts.fargs))
end, { nargs = '*' })

vim.api.nvim_create_user_command('NeoReplayExportAsciinema', function(opts)
  neoreplay.export_asciinema(parse_args(opts.fargs))
end, { nargs = '*' })

vim.api.nvim_create_user_command('NeoReplayChronos', function(opts)
  neoreplay.chronos(parse_args(opts.fargs))
end, { nargs = '*' })

vim.api.nvim_create_user_command('NeoReplayFlexChronos', neoreplay.flex_chronos, {})

vim.api.nvim_create_user_command('NeoReplayRecordFFmpeg', function(opts)
  neoreplay.record_ffmpeg(opts.args ~= "" and opts.args or nil)
end, { nargs = '?' })

vim.api.nvim_create_user_command('NeoReplayVHSThemes', function()
  neoreplay.show_vhs_themes()
end, {})

vim.api.nvim_create_user_command('NeoReplayStats', neoreplay.stats, {})

vim.api.nvim_create_user_command('NeoReplayCleanup', neoreplay.cleanup, {})

-- Seek commands
vim.api.nvim_create_user_command('NeoReplaySeek', function(opts)
  local percent = tonumber(opts.args) or 0
  neoreplay.seek_to(percent)
end, { nargs = 1 })

vim.api.nvim_create_user_command('NeoReplaySeekForward', function(opts)
  local seconds = tonumber(opts.args) or 5
  neoreplay.seek_forward(seconds)
end, { nargs = '?' })

vim.api.nvim_create_user_command('NeoReplaySeekBackward', function(opts)
  local seconds = tonumber(opts.args) or 5
  neoreplay.seek_backward(seconds)
end, { nargs = '?' })

vim.api.nvim_create_user_command('NeoReplaySeekToStart', neoreplay.seek_to_start, {})

vim.api.nvim_create_user_command('NeoReplaySeekToEnd', neoreplay.seek_to_end, {})
