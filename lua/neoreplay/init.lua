local recorder = require('neoreplay.recorder')
local replay = require('neoreplay.replay')
local storage = require('neoreplay.storage')
local chronos = require('neoreplay.chronos')

local M = {}

function M.start()
  recorder.start()
  vim.notify("NeoReplay: Started recording.", vim.log.levels.INFO)
end

function M.stop()
  recorder.stop()
  vim.notify("NeoReplay: Stopped recording.", vim.log.levels.INFO)
end

function M.play()
  replay.play()
end

function M.chronos(opts)
  local bufnr = vim.api.nvim_get_current_buf()
  local data = chronos.excavate(bufnr)
  if data then
    storage.load_chronos_session(bufnr, data)
    vim.notify("NeoReplay: History excavated. Starting replay...", vim.log.levels.INFO)
    
    opts = opts or {}
    opts.title = opts.title or "⏳ CHRONOS REPLAY"
    replay.play(opts)
  end
end

function M.flex_chronos()
  M.chronos({ speed = 100.0, title = "⚡ CHRONOS FLEX ⚡" })
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
  M._export_vhs_internal(opts)
end

function M.export_mp4(opts)
  opts = opts or {}
  opts.format = "mp4"
  M._export_vhs_internal(opts)
end

function M.record_ffmpeg(filename)
  local winid = vim.api.nvim_get_vvar('windowid')
  if not winid or winid == 0 then
    vim.notify("NeoReplay: Window ID not found. Recording requires Neovim in a GUI or supported terminal.", vim.log.levels.ERROR)
    return
  end

  -- Detect geometry (Linux/X11 specific technically, but impressive)
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

  filename = filename or vim.fn.expand('~/neoreplay_capture.mp4')
  
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

function M._export_vhs_internal(opts)
  local session = storage.get_session()
  if not session or #session.events == 0 then
    vim.notify("NeoReplay: No session recorded to export.", vim.log.levels.WARN)
    return
  end

  local format = opts.format or "gif"
  local speed = opts.speed or 20.0
  local quality = opts.quality or 100
  local filename = opts.filename or ("neoreplay." .. format)
  
  -- Theme detection
  local theme = vim.g.neoreplay_vhs_theme
  if not theme then
    local vhs_themes = {
      ["catppuccin-mocha"] = "Catppuccin Mocha",
      ["catppuccin-frappe"] = "Catppuccin Frappe",
      ["catppuccin-macchiato"] = "Catppuccin Macchiato",
      ["catppuccin-latte"] = "Catppuccin Latte",
      ["tokyonight"] = "Tokyo Night",
      ["nord"] = "Nord",
      ["dracula"] = "Dracula",
      ["gruvbox-dark"] = "Gruvbox Dark",
      ["gruvbox-light"] = "Gruvbox Light",
      ["monokai"] = "Monokai",
    }
    -- Add user mappings
    local user_mappings = vim.g.neoreplay_vhs_mappings or {}
    for k, v in pairs(user_mappings) do
      vhs_themes[k:lower()] = v
    end

    local current_colorscheme = vim.g.colors_name or ""
    theme = vhs_themes[current_colorscheme:lower()] or "Catppuccin Frappe"
  end

  local json_path = vim.fn.expand('/tmp/neoreplay_vhs.json')
  local tape_path = vim.fn.expand('~/neoreplay.tape')
  
  -- 1. Save current session to tmp
  local data = vim.fn.json_encode(session)
  local f = io.open(json_path, "w")
  if f then f:write(data) f:close() end

  -- Calculate duration
  local duration = 5 -- fallback
  if #session.events > 1 then
    duration = (session.events[#session.events].timestamp - session.events[1].timestamp) / speed
  end
  duration = math.ceil(duration) + 2 -- Add buffer

  -- 2. Generate VHS Tape
  local tape = {
    'Output ' .. filename,
    'Set FontSize 16',
    'Set Width 1200',
    'Set Height 800',
    'Set Padding 20',
    'Set Theme "' .. theme .. '"',
    format == "mp4" and 'Set Quality ' .. quality or '',
    'Hide',
    'Type "nvim -u NONE -c \'set runtimepath+=.\' -c \'lua require(\"neoreplay\").load_session(\"' .. json_path .. '\")\' -c \'lua require(\"neoreplay\").play({ speed = ' .. speed .. ' })\'\"',
    'Enter',
    'Sleep 1s',
    'Show',
    'Sleep ' .. duration .. 's',
    'Type "q"',
    'Sleep 500ms',
  }

  local tf = io.open(tape_path, "w")
  if tf then
    tf:write(table.concat(tape, "\n"))
    tf:close()
    vim.notify(string.format("NeoReplay: Tape for %s generated at %s. (Speed: %.1fx). Run `vhs < %s`", format:upper(), tape_path, speed, tape_path), vim.log.levels.INFO)
  end
end

function M.export_vhs()
  M.export_gif()
end

function M.flex()
  vim.notify("NEO REPLAY FLEX MODE: 100x SPEED ACTIVATED", vim.log.levels.INFO)
  replay.play({ speed = 100.0, title = "[FLEX MODE]" })
end

function M.export()
  local session = storage.get_session()
  local data = vim.fn.json_encode(session)
  local path = vim.fn.expand('~/neoreplay_session.json')
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
  
  -- Playback options
  vim.g.neoreplay_playback_speed = opts.playback_speed or 20.0
  
  -- Export options
  vim.g.neoreplay_vhs_theme = opts.vhs_theme -- can be nil for auto-detect
  vim.g.neoreplay_vhs_mappings = opts.vhs_mappings or {}
end

return M
