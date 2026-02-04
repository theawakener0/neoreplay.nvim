local M = {}

M.controls = " [SPACE] Pause/Play  [=/-] Speed Up/Down  [q] Quit  [f] Fullscreen "

-- Debounce state
local debounce_timers = {}
local pending_annotations = {}

-- Track active replay windows for resize handling
local active_windows = {}
local active_scenes = {}
local next_scene_id = 1
local resize_augroup = vim.api.nvim_create_augroup('neoreplay_resize', { clear = true })

local annotation_ns = vim.api.nvim_create_namespace('neoreplay_ui')

local chrome_enabled = true

function M.set_chrome_enabled(enabled)
  chrome_enabled = enabled ~= false
end

local function stop_timer(timer)
  if not timer then return end
  if type(timer) == "number" then
    pcall(vim.fn.timer_stop, timer)
  elseif timer.stop then
    pcall(timer.stop, timer)
    pcall(timer.close, timer)
  end
end

-- Normalize fullscreen option to boolean
local function normalize_fullscreen(value)
  if value == nil then return false end
  if type(value) == "boolean" then return value end
  if type(value) == "string" then
    return value:lower() == "true" or value == "1"
  end
  if type(value) == "number" then
    return value ~= 0
  end
  return false
end

-- Calculate validated window dimensions
local function calculate_dimensions(fullscreen)
  local min_width = 20
  local min_height = 5
  local screen_cols = vim.o.columns
  local screen_lines = vim.o.lines
  local cmd_height = vim.o.cmdheight or 1
  local status_height = (vim.o.laststatus or 0) > 0 and 1 or 0
  local usable_lines = math.max(1, screen_lines - cmd_height - status_height)
  
  local width, height, row, col
  if fullscreen then
    width = screen_cols
    height = usable_lines
    row = 0
    col = 0
  else
    width = math.floor(screen_cols * 0.8)
    height = math.floor(usable_lines * 0.8)
    row = math.floor((usable_lines - height) / 2)
    col = math.floor((screen_cols - width) / 2)
  end
  
  -- Validate minimum dimensions
  width = math.max(min_width, math.min(width, screen_cols))
  height = math.max(min_height, math.min(height, usable_lines))
  
  -- Recalculate position if dimensions were constrained
  if not fullscreen then
    row = math.floor((usable_lines - height) / 2)
    col = math.floor((screen_cols - width) / 2)
  end
  
  return width, height, row, col
end

local function apply_scene_layout(scene_id)
  local scene = active_scenes[scene_id]
  if not scene then return end

  local valid_winids = {}
  for _, winid in ipairs(scene.winids) do
    if winid and vim.api.nvim_win_is_valid(winid) then
      table.insert(valid_winids, winid)
    else
      active_windows[winid] = nil
    end
  end
  scene.winids = valid_winids
  if #scene.winids == 0 then
    active_scenes[scene_id] = nil
    return
  end

  local total_width, total_height, start_row, start_col = calculate_dimensions(scene.fullscreen)
  local num_windows = #scene.winids
  local win_width = math.floor(total_width / num_windows)
  local border_pad = scene.use_chrome and 2 or 0
  local row = start_row + (scene.use_chrome and 1 or 0)
  local inner_height = math.max(1, total_height - border_pad)

  for i, winid in ipairs(scene.winids) do
    local width = (i == num_windows) and (total_width - (i - 1) * win_width) or win_width
    local col = start_col + (i - 1) * win_width + (scene.use_chrome and 1 or 0)
    local inner_width = math.max(1, width - border_pad)

    local new_config = {
      relative = 'editor',
      width = inner_width,
      height = inner_height,
      row = row,
      col = col,
      border = scene.use_chrome and 'rounded' or 'none',
      title = scene.use_chrome and (' Buffer ' .. i .. ' ') or nil,
      title_pos = scene.use_chrome and 'center' or nil,
    }

    pcall(vim.api.nvim_win_set_config, winid, new_config)

    local config = active_windows[winid]
    if config then
      config.fullscreen = scene.fullscreen
      config.width = width
      config.height = total_height
    end
  end
end

-- Handle window resize
local function handle_resize()
  local handled = {}

  for scene_id, _ in pairs(active_scenes) do
    apply_scene_layout(scene_id)
    local scene = active_scenes[scene_id]
    if scene then
      for _, winid in ipairs(scene.winids) do
        handled[winid] = true
      end
    end
  end

  for winid, config in pairs(active_windows) do
    if handled[winid] then
      goto continue
    end
    if vim.api.nvim_win_is_valid(winid) then
      local width, height, row, col = calculate_dimensions(config.fullscreen)

      local new_config = {
        relative = 'editor',
        width = width,
        height = height,
        row = row,
        col = col,
        border = (config.opts and config.opts.ui_chrome ~= nil) and (config.opts.ui_chrome and 'rounded' or 'none') or (chrome_enabled and 'rounded' or 'none'),
      }

      pcall(vim.api.nvim_win_set_config, winid, new_config)

      -- Update stored dimensions
      config.width = width
      config.height = height
    else
      active_windows[winid] = nil
    end
    ::continue::
  end
end

-- Setup resize handler
local function setup_resize_handler()
  vim.api.nvim_clear_autocmds({ group = resize_augroup })
  vim.api.nvim_create_autocmd('VimResized', {
    group = resize_augroup,
    callback = handle_resize,
    desc = 'NeoReplay: Handle window resize',
  })
end

-- Toggle fullscreen for a window
function M.toggle_fullscreen(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  
  local config = active_windows[winid]
  if not config then
    return false
  end

  if config.scene_id then
    local scene = active_scenes[config.scene_id]
    if not scene then
      return false
    end
    scene.fullscreen = not scene.fullscreen
    apply_scene_layout(config.scene_id)
    return scene.fullscreen
  end
  
  -- Toggle fullscreen state
  config.fullscreen = not config.fullscreen
  
  -- Recalculate and apply dimensions
  local width, height, row, col = calculate_dimensions(config.fullscreen)
  local use_chrome = chrome_enabled
  if config.opts and config.opts.ui_chrome ~= nil then
    use_chrome = config.opts.ui_chrome
  end
  
  local new_config = {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    border = use_chrome and 'rounded' or 'none',
  }
  
  pcall(vim.api.nvim_win_set_config, winid, new_config)
  
  -- Update stored dimensions
  config.width = width
  config.height = height
  
  return config.fullscreen
end

local function escape_winbar(text)
  return tostring(text):gsub("%%", "%%%%")
end

local function setup_replay_buffer(bufnr, original_bufnr)
  vim.api.nvim_buf_set_option(bufnr, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(bufnr, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(bufnr, 'swapfile', false)
  vim.api.nvim_buf_set_option(bufnr, 'undolevels', -1)
  vim.api.nvim_buf_set_option(bufnr, 'readonly', false)
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
  vim.keymap.set('n', 'f', function() M.toggle_fullscreen(vim.api.nvim_get_current_win()) end, { buffer = bufnr, desc = "Toggle fullscreen" })
end

function M.create_replay_window(original_bufnr, opts)
  opts = opts or {}
  local fullscreen = normalize_fullscreen(opts.fullscreen)
  local use_chrome = chrome_enabled
  if opts.ui_chrome ~= nil then
    use_chrome = opts.ui_chrome
  end

  local width, height, row, col = calculate_dimensions(fullscreen)

  local bufnr = vim.api.nvim_create_buf(false, true)
  setup_replay_buffer(bufnr, original_bufnr)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = use_chrome and 'rounded' or 'none',
    title = use_chrome and ' NeoReplay ' or nil,
    title_pos = use_chrome and 'center' or nil,
  })

  if use_chrome then
    vim.api.nvim_set_option_value('winbar', M.controls, { scope = 'local', win = winid })
  end

  active_windows[winid] = {
    fullscreen = fullscreen,
    width = width,
    height = height,
    opts = opts,
    bufnr = bufnr,
  }

  setup_resize_handler()

  return bufnr, winid
end

function M.create_scene_windows(original_bufnrs, focus_bufnr, opts)
  opts = opts or {}
  local fullscreen = normalize_fullscreen(opts.fullscreen)
  local use_chrome = chrome_enabled
  if opts.ui_chrome ~= nil then
    use_chrome = opts.ui_chrome
  end

  local bufnr_map = {}
  local win_map = {}
  local focus_buf = focus_bufnr or original_bufnrs[1]

  -- Use floating windows with tiled layout for both fullscreen and windowed scenes
  local total_width, total_height, start_row, start_col = calculate_dimensions(fullscreen)
  local num_windows = #original_bufnrs
  local win_width = math.floor(total_width / num_windows)
  local border_pad = use_chrome and 2 or 0
  local row = start_row + (use_chrome and 1 or 0)
  local inner_height = math.max(1, total_height - border_pad)

  for i, original in ipairs(original_bufnrs) do
    local bufnr = vim.api.nvim_create_buf(false, true)
    setup_replay_buffer(bufnr, original)

    local width = (i == num_windows) and (total_width - (i - 1) * win_width) or win_width
    local col = start_col + (i - 1) * win_width + (use_chrome and 1 or 0)
    local inner_width = math.max(1, width - border_pad)

    local winid = vim.api.nvim_open_win(bufnr, i == 1, {
      relative = 'editor',
      width = inner_width,
      height = inner_height,
      row = row,
      col = col,
      style = 'minimal',
      border = use_chrome and 'rounded' or 'none',
      title = use_chrome and (' Buffer ' .. i .. ' ') or nil,
      title_pos = use_chrome and 'center' or nil,
    })

    if use_chrome then
      vim.api.nvim_set_option_value('winbar', M.controls, { scope = 'local', win = winid })
    end

    bufnr_map[original] = bufnr
    win_map[original] = winid

    active_windows[winid] = {
      fullscreen = fullscreen,
      width = width,
      height = total_height,
      opts = opts,
      bufnr = bufnr,
    }
  end

  local scene_id = next_scene_id
  next_scene_id = next_scene_id + 1
  local scene_winids = {}
  for _, original in ipairs(original_bufnrs) do
    table.insert(scene_winids, win_map[original])
  end
  active_scenes[scene_id] = {
    winids = scene_winids,
    fullscreen = fullscreen,
    use_chrome = use_chrome,
    opts = opts,
  }

  for i, original in ipairs(original_bufnrs) do
    local winid = win_map[original]
    if active_windows[winid] then
      active_windows[winid].scene_id = scene_id
      active_windows[winid].scene_index = i
    end
  end

  setup_resize_handler()

  -- Focus primary track
  if focus_buf and win_map[focus_buf] then
    pcall(vim.api.nvim_set_current_win, win_map[focus_buf])
  end

  return bufnr_map, win_map
end

-- Immediate progress update (use sparingly)
function M.set_progress(winid, progress)
  if not chrome_enabled then return end
  if not winid or not vim.api.nvim_win_is_valid(winid) then return end
    local text = string.format("%s | %d%%", M.controls, progress)
    vim.api.nvim_set_option_value('winbar', escape_winbar(text), { scope = 'local', win = winid })
end

-- Immediate annotation update (use sparingly)
function M.set_annotation(winid, annotation)
  if not chrome_enabled then return end
  if not winid or not vim.api.nvim_win_is_valid(winid) then return end
    local text = string.format("%s | %s", M.controls, annotation or "")
    vim.api.nvim_set_option_value('winbar', escape_winbar(text), { scope = 'local', win = winid })
end

-- Debounced annotation update (preferred for high-frequency updates)
function M.set_annotation_debounced(winid, annotation, delay_ms)
  if not chrome_enabled then return end
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
  active_windows = {}
  active_scenes = {}
  next_scene_id = 1
  vim.api.nvim_clear_autocmds({ group = resize_augroup })
end

return M
