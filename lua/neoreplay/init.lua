local recorder = require('neoreplay.recorder')
local replay = require('neoreplay.replay')
local storage = require('neoreplay.storage')
local chronos = require('neoreplay.chronos')
local exporters = require('neoreplay.exporters')
local vhs_exporter = require('neoreplay.exporters.vhs')
local frames_exporter = require('neoreplay.exporters.frames')
local asciinema_exporter = require('neoreplay.exporters.asciinema')
local vhs_themes = require('neoreplay.vhs_themes')
local ui = require('neoreplay.ui')

local M = {}

exporters.register('vhs', vhs_exporter)
exporters.register('frames', frames_exporter)
exporters.register('asciinema', asciinema_exporter)

function M.capabilities()
  return {
    vhs = vhs_exporter.available and vhs_exporter.available() or false,
    asciinema = asciinema_exporter.available and asciinema_exporter.available() or false,
    frames = true,
    ffmpeg = vim.fn.executable('ffmpeg') == 1,
  }
end

function M.list_vhs_themes()
  return vhs_themes.all
end

function M.show_vhs_themes()
  local themes = vhs_themes.all
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(bufnr, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(bufnr, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, themes)
  vim.api.nvim_buf_set_option(bufnr, 'modifiable', false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.notify("NeoReplay: VHS themes list opened.", vim.log.levels.INFO)
end

function M.start(opts)
  recorder.start(opts)
  vim.notify("NeoReplay: Started recording.", vim.log.levels.INFO)
end

function M.stop()
  recorder.stop()
  vim.notify("NeoReplay: Stopped recording.", vim.log.levels.INFO)
end

function M.play()
  replay.play()
end

function M.clear()
  storage.start()
  storage.stop()
  vim.notify("NeoReplay: Session cleared.", vim.log.levels.INFO)
end

function M.chronos(opts)
  local bufnr = vim.api.nvim_get_current_buf()
  opts = opts or {}
  local data = chronos.excavate(bufnr, opts)
  if data then
    storage.load_chronos_session(bufnr, data)
    vim.notify("NeoReplay: History excavated. Starting replay...", vim.log.levels.INFO)
    
    opts = opts or {}
    opts.title = opts.title or "[CHRONOS REPLAY]"
    replay.play(opts)
  end
end

function M.flex_chronos()
  M.chronos({ speed = 100.0, title = "[CHRONOS FLEX]" })
end

function M.load_session(path)
  local f = io.open(path, "r")
  if not f then
    vim.notify("NeoReplay: Could not open session file: " .. path, vim.log.levels.ERROR)
    return
  end
  local content = f:read("*all")
  f:close()
  local data = vim.fn.json_decode(content)
  storage.load_session(data)
  vim.notify("NeoReplay: Session loaded from " .. path, vim.log.levels.INFO)
end

function M.export_gif(opts)
  opts = opts or {}
  opts.format = "gif"
  exporters.export('vhs', opts)
end

function M.export_mp4(opts)
  opts = opts or {}
  opts.format = "mp4"
  exporters.export('vhs', opts)
end

function M.record_ffmpeg(filename)
  local winid = vim.api.nvim_get_vvar('windowid')
  if not winid or winid == 0 then
    vim.notify("NeoReplay: Window ID not found. Recording requires Neovim in a GUI or supported terminal.", vim.log.levels.ERROR)
    return
  end

  local cmd = string.format("xwininfo -id %d | grep -E 'Width:|Height:|Absolute-upper-left-X:|Absolute-upper-left-Y:'", winid)
  local handle = io.popen(cmd)
  local result = handle:read("*a")
  handle:close()

  local w = result:match("Width: (%d+)")
  local h = result:match("Height: (%d+)")
  local x = result:match("Absolute%-upper%-left%-X: (%d+)")
  local y = result:match("Absolute%-upper%-left%-Y: (%d+)")

  if not (w and h and x and y) then
    vim.notify("NeoReplay: Failed to detect window geometry. Is 'xwininfo' installed?", vim.log.levels.ERROR)
    return
  end

  filename = filename or vim.fn.expand('~/.neoreplay/neoreplay_capture.mp4')
  
  -- FFmpeg command for internal screen grab (X11)
  local ffmpeg_cmd = string.format(
    "ffmpeg -y -f x11grab -video_size %dx%d -i :0.0+%d,%d -codec:v libx264 -crf 18 -pix_fmt yuv420p %s",
    w, h, x, y, filename
  )

  local job_id = vim.fn.jobstart(ffmpeg_cmd)
  if job_id <= 0 then
    vim.notify("NeoReplay: Failed to start FFmpeg. Is it installed?", vim.log.levels.ERROR)
    return
  end

  vim.notify("NeoReplay: FFmpeg recording started...", vim.log.levels.INFO)

  -- Start playback and stop ffmpeg when done
  replay.play({
    on_finish = function()
      vim.fn.jobstop(job_id)
      vim.notify("NeoReplay: FFmpeg recording saved to " .. filename, vim.log.levels.INFO)
    end
  })
end

function M.export_frames(opts)
  exporters.export('frames', opts or {})
end

function M.export_asciinema(opts)
  exporters.export('asciinema', opts or {})
end

function M.export_vhs()
  M.export_gif()
end

function M.flex()
  vim.notify("NEO REPLAY FLEX MODE: 100x SPEED ACTIVATED", vim.log.levels.INFO)
  replay.play({ speed = 100.0, title = "[FLEX MODE]" })
end

function M.stats()
  local s = storage.get_stats()
  vim.notify(string.format(
    "NeoReplay Stats: %d events | %d buffers | Cache: %d strings",
    s.events, s.buffers, s.string_cache_size
  ), vim.log.levels.INFO)
end

-- Seek functions
function M.seek_forward(seconds)
  local progress_bar = require('neoreplay.progress_bar')
  progress_bar.seek_relative(seconds or 5)
end

function M.seek_backward(seconds)
  M.seek_forward(-(seconds or 5))
end

function M.seek_to_start()
  M.seek_backward(999999) -- Large negative to go to start
end

function M.seek_to_end()
  M.seek_forward(999999) -- Large positive to go to end
end

function M.seek_to(percent)
  local progress_bar = require('neoreplay.progress_bar')
  progress_bar.seek_to_percent(percent / 100)
end

function M.cleanup()
  storage.clear_string_cache()
  ui.cleanup()
  vim.notify("NeoReplay: Memory caches cleared", vim.log.levels.INFO)
end

function M.export()
  local session = storage.get_session()
  local data = vim.fn.json_encode(session)
  local base_dir = vim.fn.expand('~/.neoreplay')
  vim.fn.mkdir(base_dir, 'p')
  local path = base_dir .. '/neoreplay_session.json'
  local f = io.open(path, "w")
  if f then
    f:write(data)
    f:close()
    print("NeoReplay: Session exported to " .. path)
  else
    print("NeoReplay: Failed to export session.")
  end
end

function M.setup(opts)
  opts = opts or {}
  
  -- Recording options
  vim.g.neoreplay_ignore_whitespace = opts.ignore_whitespace or false
  vim.g.neoreplay_record_all_buffers = opts.record_all_buffers or false
  
  -- Playback options
  vim.g.neoreplay_playback_speed = opts.playback_speed or 20.0
  
  -- Export options
  vim.g.neoreplay_vhs_theme = opts.vhs_theme
  vim.g.neoreplay_vhs_mappings = opts.vhs_mappings or {}

  -- Replay control keys
  local controls = opts.controls or {}
  vim.g.neoreplay_controls = {
    quit = controls.quit or 'q',
    quit_alt = controls.quit_alt or '<Esc>',
    pause = controls.pause or '<space>',
    faster = controls.faster or '=',
    slower = controls.slower or '-',
  }

  -- Keymaps
  if opts.keymaps then
    local maps = opts.keymaps
    if maps.start then vim.keymap.set('n', maps.start, M.start, { desc = "NeoReplay: Start recording" }) end
    if maps.stop then vim.keymap.set('n', maps.stop, M.stop, { desc = "NeoReplay: Stop recording" }) end
    if maps.play then vim.keymap.set('n', maps.play, M.play, { desc = "NeoReplay: Start replay" }) end
    if maps.flex then vim.keymap.set('n', maps.flex, M.flex, { desc = "NeoReplay: Flex replay" }) end
    if maps.chronos then vim.keymap.set('n', maps.chronos, M.chronos, { desc = "NeoReplay: Chronos excavation" }) end
    if maps.clear then vim.keymap.set('n', maps.clear, M.clear, { desc = "NeoReplay: Clear session" }) end
    if maps.export_gif then vim.keymap.set('n', maps.export_gif, M.export_gif, { desc = "NeoReplay: Export GIF" }) end
    if maps.export_mp4 then vim.keymap.set('n', maps.export_mp4, M.export_mp4, { desc = "NeoReplay: Export MP4" }) end
    if maps.export_frames then vim.keymap.set('n', maps.export_frames, M.export_frames, { desc = "NeoReplay: Export Frames" }) end
    if maps.export_asciinema then vim.keymap.set('n', maps.export_asciinema, M.export_asciinema, { desc = "NeoReplay: Export Asciinema" }) end
    if maps.record_ffmpeg then vim.keymap.set('n', maps.record_ffmpeg, M.record_ffmpeg, { desc = "NeoReplay: Record with FFmpeg" }) end
    if maps.stats then vim.keymap.set('n', maps.stats, M.stats, { desc = "NeoReplay: Show stats" }) end
    if maps.cleanup then vim.keymap.set('n', maps.cleanup, M.cleanup, { desc = "NeoReplay: Cleanup memory" }) end
  end
end

return M
