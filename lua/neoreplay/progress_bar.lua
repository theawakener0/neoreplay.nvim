local storage = require('neoreplay.storage')
local bookmarks = require('neoreplay.bookmarks')
local M = {}

local replay_mod = nil
local function get_replay()
  if not replay_mod then
    replay_mod = require('neoreplay.replay')
  end
  return replay_mod
end

-- State
local state = {
  winid = nil,
  bufnr = nil,
  preview_winid = nil,
  preview_bufnr = nil,
  is_dragging = false,
  drag_start_x = nil,
  is_visible = false,
  total_events = 0,
  current_event = 0,
  current_time = 0,
  total_time = 0,
  width = 80,
  cached_buffer_states = {}, -- LRU cache for buffer states
  last_preview_update = 0,
  active_bufnr = nil,
  layout = nil,
  seek_timer = nil,  -- Timer for debouncing seek operations
  pending_seek = nil,  -- Pending seek percentage
  resize_autocmd = nil,  -- Handle window resize
  preview_cancelled = false,  -- Flag to cancel async preview
}

-- Configuration
local CONFIG = {
  width_percent = 0.8,
  height = 2,
  update_interval = 33,  -- ~30fps for smooth updates (was 100ms)
  preview_context = 5,
  preview_width = 40,
  preview_debounce = 50,  -- Faster hover response (was 100ms)
  drag_highlight = true,
  max_cache_size = 50,  -- Larger cache for smooth scrubbing (was 10)
  seek_debounce = 150,  -- Debounce rapid seek operations
  style = {
    filled_char = '=',
    empty_char = ' ',
    position_marker = '>',
    play_icon = '▶',
    pause_icon = '⏸',
    stop_icon = '■',
  }
}

-- Namespace for highlighting
local ns_id = vim.api.nvim_create_namespace('neoreplay_progress')

-- Validation helpers
local function is_valid_state()
  return state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr)
    and state.winid and vim.api.nvim_win_is_valid(state.winid)
end

local function safe_get_buffer_name(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return "[Invalid]"
  end
  local ok, name = pcall(vim.api.nvim_buf_get_name, bufnr)
  if not ok or not name or name == "" then
    return "[No Name]"
  end
  return vim.fn.fnamemodify(name, ':t')
end

local function clamp_percent(percent)
  if type(percent) ~= "number" or percent ~= percent then  -- NaN check
    return 0
  end
  return math.max(0, math.min(1, percent))
end

-- Helper: Format time as MM:SS
local function format_time(seconds)
  local mins = math.floor(seconds / 60)
  local secs = math.floor(seconds % 60)
  return string.format("%02d:%02d", mins, secs)
end

local function build_layout(percent, buf_name, time_str, pct_str, play_icon)
  local time_block_len = #time_str + 2
  local pct_len = #pct_str
  local play_len = #play_icon
  local fixed_len = time_block_len + 4 + pct_len + play_len
  local available = state.width - fixed_len
  if available < 3 then available = 3 end

  local min_bar_len = 12
  local bar_len = available - #buf_name
  if bar_len < min_bar_len then
    bar_len = math.min(available, min_bar_len)
  end
  if bar_len > available then bar_len = available end

  local remaining = available - bar_len
  local display_name = buf_name
  if remaining <= 0 then
    display_name = ""
  elseif #display_name > remaining then
    if remaining == 1 then
      display_name = "…"
    else
      display_name = display_name:sub(1, remaining - 1) .. "…"
    end
  end

  local bar_width = math.max(1, bar_len - 2)
  return {
    time_block_len = time_block_len,
    bar_len = bar_len,
    bar_width = bar_width,
    bar_start_0 = time_block_len + 1,
    bar_start_1 = time_block_len + 2,
    buf_name = display_name,
  }
end

-- Helper: Calculate time from events
local function calculate_time_from_events(event_index, events)
  if #events == 0 then return 0 end
  if event_index <= 1 then return 0 end
  if event_index >= #events then
    return events[#events].timestamp - events[1].timestamp
  end
  return events[event_index].timestamp - events[1].timestamp
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

-- Create progress bar window
function M.create(opts)
  opts = opts or {}
  state.total_events = opts.total_events or 0
  state.current_event = 0
  state.active_bufnr = opts.active_bufnr
  state.current_time = 0
  state.total_time = opts.total_time or 0
  state.cached_buffer_states = {}
  state.is_fullscreen = normalize_fullscreen(opts.fullscreen)
  
  -- Calculate dimensions
  local screen_width = vim.o.columns
  local screen_height = vim.o.lines
  state.width = math.floor(screen_width * CONFIG.width_percent)
  local bar_col = math.floor((screen_width - state.width) / 2)
  -- In fullscreen mode, position at bottom with less margin
  local bar_row = state.is_fullscreen and (screen_height - 2) or (screen_height - 3) 
  
  -- Create buffer
  state.bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(state.bufnr, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(state.bufnr, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(state.bufnr, 'modifiable', true)
  
  -- Create window
  state.winid = vim.api.nvim_open_win(state.bufnr, false, {
    relative = 'editor',
    width = state.width,
    height = CONFIG.height,
    row = bar_row,
    col = bar_col,
    style = 'minimal',
    border = 'rounded',
    focusable = true,
    zindex = 100,
  })
  
  state.is_visible = true
  
  -- Setup keymaps for interaction
  M.setup_keymaps()
  
  -- Setup resize autocmd
  if state.resize_autocmd then
    pcall(vim.api.nvim_del_autocmd, state.resize_autocmd)
  end
  state.resize_autocmd = vim.api.nvim_create_autocmd('VimResized', {
    group = vim.api.nvim_create_augroup('NeoReplayProgressBar', { clear = false }),
    callback = function()
      if state.is_visible then
        M.recalculate_dimensions()
      end
    end,
  })
  
  -- Initial draw
  M.draw()
  
  return state.winid, state.bufnr
end

-- Recalculate dimensions on resize
function M.recalculate_dimensions()
  if not state.is_visible or not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return
  end
  
  local screen_width = vim.o.columns
  local screen_height = vim.o.lines
  state.width = math.floor(screen_width * CONFIG.width_percent)
  local bar_col = math.floor((screen_width - state.width) / 2)
  local bar_row = state.is_fullscreen and (screen_height - 2) or (screen_height - 3)
  
  -- Update window config
  local ok = pcall(vim.api.nvim_win_set_config, state.winid, {
    relative = 'editor',
    width = state.width,
    row = bar_row,
    col = bar_col,
  })
  
  if ok then
    -- Force redraw to update layout
    M.draw()
  end
end

-- Setup mouse and keyboard keymaps
function M.setup_keymaps()
  if not state.bufnr then return end

  local controls = vim.g.neoreplay_controls or {}
  local quit = controls.quit or 'q'
  local quit_alt = controls.quit_alt or '<Esc>'
  local pause = controls.pause or '<space>'
  local faster = controls.faster or '='
  local slower = controls.slower or '-'
  
  -- Mouse click to seek
  vim.keymap.set('n', '<LeftMouse>', function()
    if not state.is_visible then return end
    local pos = vim.fn.getmousepos()
    if pos.winid == state.winid then
      M.handle_click(pos.column)
    end
  end, { buffer = state.bufnr, silent = true })
  
  -- Mouse drag start
  vim.keymap.set('n', '<LeftDrag>', function()
    if not state.is_visible then return end
    local pos = vim.fn.getmousepos()
    if pos.winid == state.winid then
      M.handle_drag(pos.column)
    end
  end, { buffer = state.bufnr, silent = true })
  
  -- Mouse drag end (release)
  vim.keymap.set('n', '<LeftRelease>', function()
    if state.is_dragging then
      local pos = vim.fn.getmousepos()
      M.handle_drag_end(pos.column)
    end
  end, { buffer = state.bufnr, silent = true })
  
  -- Mouse move for hover preview
  vim.keymap.set('n', '<MouseMove>', function()
    if not state.is_visible then return end
    local pos = vim.fn.getmousepos()
    if pos.winid == state.winid then
      M.handle_hover(pos.column)
    else
      M.hide_preview()
    end
  end, { buffer = state.bufnr, silent = true })
  
  -- Keyboard shortcuts
  vim.keymap.set('n', 'h', function() M.seek_relative(-5) end, 
    { buffer = state.bufnr, desc = "Seek backward 5s" })
  vim.keymap.set('n', 'l', function() M.seek_relative(5) end,
    { buffer = state.bufnr, desc = "Seek forward 5s" })
  vim.keymap.set('n', 'H', function() M.seek_relative(-30) end,
    { buffer = state.bufnr, desc = "Seek backward 30s" })
  vim.keymap.set('n', 'L', function() M.seek_relative(30) end,
    { buffer = state.bufnr, desc = "Seek forward 30s" })
  vim.keymap.set('n', '0', function() M.seek_to_percent(0) end,
    { buffer = state.bufnr, desc = "Seek to start" })
  vim.keymap.set('n', 'G', function() M.seek_to_percent(100) end,
    { buffer = state.bufnr, desc = "Seek to end" })
  vim.keymap.set('n', '$', function() M.seek_to_percent(100) end,
    { buffer = state.bufnr, desc = "Seek to end" })

  -- Replay controls (same as main replay window)
  vim.keymap.set('n', quit, function() require('neoreplay.replay').stop_playback() end,
    { buffer = state.bufnr, desc = "Quit replay" })
  vim.keymap.set('n', quit_alt, function() require('neoreplay.replay').stop_playback() end,
    { buffer = state.bufnr, desc = "Quit replay" })
  vim.keymap.set('n', pause, function() require('neoreplay.replay').toggle_pause() end,
    { buffer = state.bufnr, desc = "Pause/Play" })
  vim.keymap.set('n', faster, function() require('neoreplay.replay').speed_up() end,
    { buffer = state.bufnr, desc = "Speed up" })
  vim.keymap.set('n', slower, function() require('neoreplay.replay').speed_down() end,
    { buffer = state.bufnr, desc = "Speed down" })
end

-- Draw the progress bar
function M.draw()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end
  
  local total = math.max(1, state.total_events)
  local current = math.max(0, math.min(state.current_event, total))
  local percent = current / total
  
  -- Edge case: clamp to valid range
  percent = clamp_percent(percent)
  
  -- Format time
  local time_str = format_time(state.current_time) .. " / " .. format_time(state.total_time)
  
  -- Format percentage
  local pct_str = string.format("%3d%%", math.floor(percent * 100))
  
  -- Get active buffer name safely
  local buf_name = safe_get_buffer_name(state.active_bufnr)
  
  -- Check if playing (with error handling)
  local ok, replay = pcall(get_replay)
  local is_playing = false
  if ok and replay and replay.is_playing then
    local ok2, playing = pcall(replay.is_playing)
    if ok2 then
      is_playing = playing
    end
  end
  local play_icon = is_playing and CONFIG.style.pause_icon or CONFIG.style.play_icon

  -- Build layout with error handling
  local ok2, layout = pcall(build_layout, percent, buf_name, time_str, pct_str, play_icon)
  if not ok2 then
    -- Fallback to basic layout on error
    layout = {
      time_block_len = #time_str + 2,
      bar_len = 20,
      bar_width = 18,
      bar_start_0 = #time_str + 2,
      bar_start_1 = #time_str + 3,
      buf_name = buf_name,
    }
  end
  
  state.layout = layout
  buf_name = layout.buf_name
  local bar_width = layout.bar_width
  local filled = math.floor(percent * (bar_width - 1))
  if filled < 0 then filled = 0 end
  if filled > (bar_width - 1) then filled = bar_width - 1 end
  local empty = math.max(0, bar_width - filled - 1)

  -- Build progress bar
  local bar_chars = {}
  for i = 1, bar_width - 1 do
    if i <= filled then
      table.insert(bar_chars, CONFIG.style.filled_char)
    else
      table.insert(bar_chars, CONFIG.style.empty_char)
    end
  end
  
  -- Overlay bookmarks
  local bks = bookmarks.get_all()
  for _, bk in ipairs(bks) do
    local bk_percent = bk.event_index / math.max(1, state.total_events)
    local bk_pos = math.floor(bk_percent * (bar_width - 1)) + 1
    if bk_pos >= 1 and bk_pos <= #bar_chars then
      bar_chars[bk_pos] = "󰃁" -- Bookmark icon
    end
  end
  
  -- Overlay position marker (after bookmarks so it shows on top)
  if filled + 1 <= #bar_chars then
    bar_chars[filled + 1] = CONFIG.style.position_marker
  end

  local bar = "[" .. table.concat(bar_chars) .. "]"
  
  local line1 = string.format("[%s] %s %s %s %s", 
    time_str, bar, pct_str, play_icon, buf_name)
  
  local line2 = " [←/→:5s  H/L:30s  0:start  G:end  Drag:scrub  Click:seek ]"
  
  -- Update buffer with error handling
  local ok3 = pcall(function()
    vim.api.nvim_buf_set_option(state.bufnr, 'modifiable', true)
    vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, {line1, line2})
    vim.api.nvim_buf_set_option(state.bufnr, 'modifiable', false)
  end)
  
  if not ok3 then
    return  -- Buffer was likely closed
  end
  
  -- Apply highlighting
  M.apply_highlights()
end

-- Apply syntax highlighting
function M.apply_highlights()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end

  local layout = state.layout
  if not layout then return end
  
  if not layout.time_block_len or not layout.bar_start_0 or not layout.bar_len or not layout.bar_width then
    return
  end
  
  -- Use pcall for all highlight operations
  pcall(function()
    -- Clear existing highlights
    vim.api.nvim_buf_clear_namespace(state.bufnr, ns_id, 0, -1)
    
    -- Highlight time
    vim.api.nvim_buf_add_highlight(state.bufnr, ns_id, 'Special', 0, 0, layout.time_block_len)
    
    -- Highlight progress bar
    local bar_start = layout.bar_start_0
    local bar_end = bar_start + layout.bar_len
    vim.api.nvim_buf_add_highlight(state.bufnr, ns_id, 'DiffAdd', 0, bar_start, bar_end)
    
    -- Highlight position marker
    local total = math.max(1, state.total_events)
    local percent = state.current_event / total
    local filled = math.floor(percent * (layout.bar_width - 1))
    local marker_pos = bar_start + 1 + filled
    vim.api.nvim_buf_add_highlight(state.bufnr, ns_id, 'DiffChange', 0, marker_pos, marker_pos + 1)
    
    -- Highlight bookmarks
    local bks = bookmarks.get_all()
    for _, bk in ipairs(bks) do
      local bk_percent = bk.event_index / total
      local bk_pos = bar_start + 1 + math.floor(bk_percent * (layout.bar_width - 1))
      vim.api.nvim_buf_add_highlight(state.bufnr, ns_id, 'DiagnosticOk', 0, bk_pos, bk_pos + 1)
    end

    -- Highlight percentage
    vim.api.nvim_buf_add_highlight(state.bufnr, ns_id, 'Normal', 0, bar_end + 1, bar_end + 5)
    
    -- Highlight controls
    vim.api.nvim_buf_add_highlight(state.bufnr, ns_id, 'Comment', 1, 0, -1)
  end)
end

-- Update progress
function M.update(current_event, total_events, current_time, total_time)
  if not state.is_visible or not is_valid_state() then
    return
  end
  
  if total_events and total_events <= 0 then
    total_events = 1  -- Prevent division by zero
  end
  
  -- Update state with validation
  if current_event ~= nil then
    state.current_event = math.max(0, math.min(current_event, state.total_events))
  end
  if total_events ~= nil and total_events > 0 then
    state.total_events = total_events
  end
  if current_time ~= nil then
    state.current_time = math.max(0, current_time)
  end
  if total_time ~= nil then
    state.total_time = math.max(0, total_time)
  end
  
  -- Throttle updates for performance
  local now = vim.loop.now()
  if state.last_update and (now - state.last_update) < CONFIG.update_interval then
    return
  end
  state.last_update = now
  
  -- Use pcall to catch any errors during draw
  local ok, err = pcall(M.draw)
  if not ok then
    vim.notify("NeoReplay: Progress bar draw error: " .. tostring(err), vim.log.levels.DEBUG)
  end
end

-- Handle mouse click
function M.handle_click(col)
  local percent = M.column_to_percent(col)
  M.seek_to_percent(percent)
end

-- Handle drag start/move
function M.handle_drag(col)
  if not state.is_dragging then
    state.is_dragging = true
    state.drag_start_x = col
  end
  
  local percent = M.column_to_percent(col)
  
  -- Debounce preview updates
  local now = vim.loop.now()
  if now - state.last_preview_update >= CONFIG.preview_debounce then
    M.show_preview(percent)
    state.last_preview_update = now
  end
  
  -- Highlight drag section
  if CONFIG.drag_highlight then
    M.highlight_drag_section(percent)
  end
end

-- Handle drag end
function M.handle_drag_end(col)
  if not state.is_dragging then return end
  
  local percent = M.column_to_percent(col)
  state.is_dragging = false
  state.drag_start_x = nil
  
  M.hide_preview()
  M.seek_to_percent(percent)
  M.draw() -- Redraw to clear highlights
end

-- Handle hover
function M.handle_hover(col)
  if state.is_dragging then return end
  
  local percent = M.column_to_percent(col)
  
  -- Debounce
  local now = vim.loop.now()
  if now - state.last_preview_update >= CONFIG.preview_debounce then
    M.show_preview(percent)
    state.last_preview_update = now
  end
end

-- Convert column to percentage
function M.column_to_percent(col)
  local layout = state.layout
  local time_str = format_time(state.current_time) .. " / " .. format_time(state.total_time)
  local time_block_len = #time_str + 2
  local bar_start = layout and layout.bar_start_1 or (time_block_len + 2)
  local bar_width = layout and layout.bar_width or math.max(1, state.width - 35)
  local inner_start = bar_start + 1
  local effective_col = col - inner_start
  local percent = effective_col / bar_width
  return math.max(0, math.min(1, percent))
end

-- Show loading preview
local function show_loading_preview()
  local screen_width = vim.o.columns
  local screen_height = vim.o.lines
  local preview_width = 25
  local preview_height = 3
  local win_x = math.floor((screen_width - preview_width) / 2)
  local win_y = screen_height - 3 - preview_height - 1
  
  if not state.preview_bufnr or not vim.api.nvim_buf_is_valid(state.preview_bufnr) then
    state.preview_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(state.preview_bufnr, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(state.preview_bufnr, 'bufhidden', 'wipe')
  end
  
  vim.api.nvim_buf_set_option(state.preview_bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(state.preview_bufnr, 0, -1, false, {
    "",
    " Loading preview...",
    ""
  })
  vim.api.nvim_buf_set_option(state.preview_bufnr, 'modifiable', false)
  
  if not state.preview_winid or not vim.api.nvim_win_is_valid(state.preview_winid) then
    state.preview_winid = vim.api.nvim_open_win(state.preview_bufnr, false, {
      relative = 'editor',
      width = preview_width,
      height = preview_height,
      row = win_y,
      col = win_x,
      style = 'minimal',
      border = 'rounded',
      focusable = false,
      zindex = 101,
    })
  end
end

-- Show preview window at percentage (with async-like behavior)
function M.show_preview(percent)
  if not state.is_visible then return end
  
  -- Edge case: zero events
  if state.total_events <= 0 then
    M.show_preview_error("No events to preview")
    return
  end
  
  percent = clamp_percent(percent)
  local event_index = math.floor(percent * state.total_events)
  event_index = math.max(1, math.min(event_index, state.total_events))
  
  -- Check cache first for instant preview
  local cache_key = tostring(event_index)
  if state.cached_buffer_states[cache_key] then
    -- Use cached result immediately
    local cached = state.cached_buffer_states[cache_key]
    M.render_preview(cached.lines, cached.event_line, cached.buf_name)
    return
  end
  
  -- Show loading state first
  show_loading_preview()
  
  -- Defer heavy computation to avoid blocking UI
  vim.defer_fn(function()
    -- Check if cancelled or no longer visible
    if state.preview_cancelled or not state.is_visible then
      return
    end
    
    -- Get or calculate buffer state
    local success, lines, event_line, buf_name = pcall(M.get_buffer_state_at_event, event_index)
    
    if not success then
      M.show_preview_error("Unable to generate preview")
      return
    end
    
    if not lines or #lines == 0 then
      M.show_preview_error("No content to preview")
      return
    end
    
    -- Check again if cancelled during computation
    if state.preview_cancelled or not state.is_visible then
      return
    end
    
    -- Render the actual preview
    M.render_preview(lines, event_line, buf_name)
  end, 10)  -- Small delay to allow loading state to render
end

-- Render preview content to window
function M.render_preview(lines, event_line, buf_name)
  if not state.is_visible or state.preview_cancelled then return end
  
  if not lines or #lines == 0 then
    M.show_preview_error("Invalid preview data")
    return
  end
  
  event_line = math.max(1, math.min(event_line or 1, #lines))
  
  -- Calculate preview window position
  local screen_width = vim.o.columns
  local screen_height = vim.o.lines
  local preview_width = math.min(CONFIG.preview_width, 60)
  local preview_height = math.min(CONFIG.preview_context * 2 + 1, 15)
  
  -- Position above progress bar
  local win_x = math.floor((screen_width - preview_width) / 2)
  local win_y = screen_height - 3 - preview_height - 1 -- -1 for gap
  
  -- Create or update preview buffer
  if not state.preview_bufnr or not vim.api.nvim_buf_is_valid(state.preview_bufnr) then
    state.preview_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(state.preview_bufnr, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(state.preview_bufnr, 'bufhidden', 'wipe')
    vim.api.nvim_buf_set_option(state.preview_bufnr, 'filetype', 'lua')
  end
  
  -- Build preview content with edge case handling
  local preview_lines = {}
  local context_start = math.max(1, event_line - CONFIG.preview_context)
  local context_end = math.min(#lines, event_line + CONFIG.preview_context)
  
  for i = context_start, context_end do
    local line_num = string.format("%3d", i)
    local marker = (i == event_line) and "▶" or " "
    -- Handle very long lines
    local content = lines[i] or ""
    if #content > preview_width - 7 then
      content = content:sub(1, preview_width - 10) .. "..."
    end
    table.insert(preview_lines, string.format("%s %s│ %s", marker, line_num, content))
  end
  
  -- Add buffer name at bottom
  table.insert(preview_lines, string.rep("─", preview_width))
  local display_name = buf_name and buf_name ~= "" and buf_name or "[Unknown]"
  local file_display = "📄 " .. display_name
  if #file_display > preview_width then
    file_display = "📄 " .. display_name:sub(1, preview_width - 5) .. "..."
  end
  table.insert(preview_lines, file_display)
  
  -- Update preview buffer with error handling
  local ok = pcall(function()
    vim.api.nvim_buf_set_option(state.preview_bufnr, 'modifiable', true)
    vim.api.nvim_buf_set_lines(state.preview_bufnr, 0, -1, false, preview_lines)
    vim.api.nvim_buf_set_option(state.preview_bufnr, 'modifiable', false)
  end)
  
  if not ok then return end
  
  -- Create or update preview window
  if not state.preview_winid or not vim.api.nvim_win_is_valid(state.preview_winid) then
    local ok2, winid = pcall(vim.api.nvim_open_win, state.preview_bufnr, false, {
      relative = 'editor',
      width = preview_width,
      height = #preview_lines,
      row = win_y,
      col = win_x,
      style = 'minimal',
      border = 'rounded',
      focusable = false,
      zindex = 101,
    })
    
    if ok2 then
      state.preview_winid = winid
      -- Highlight current line
      pcall(vim.api.nvim_buf_add_highlight, state.preview_bufnr, ns_id, 'Visual', 
        event_line - context_start, 0, -1)
    end
  else
    pcall(vim.api.nvim_win_set_config, state.preview_winid, {
      relative = 'editor',
      row = win_y,
      col = win_x,
      width = preview_width,
      height = #preview_lines,
    })
  end
end

-- Show error in preview
function M.show_preview_error(msg)
  if not state.preview_bufnr then
    state.preview_bufnr = vim.api.nvim_create_buf(false, true)
  end
  
  vim.api.nvim_buf_set_option(state.preview_bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(state.preview_bufnr, 0, -1, false, {
    "",
    "  " .. msg,
    "",
    "  Unable to generate preview",
    ""
  })
  vim.api.nvim_buf_set_option(state.preview_bufnr, 'modifiable', false)
  
  -- Highlight error
  vim.api.nvim_buf_clear_namespace(state.preview_bufnr, ns_id, 0, -1)
  vim.api.nvim_buf_add_highlight(state.preview_bufnr, ns_id, 'ErrorMsg', 1, 0, -1)
end

-- Hide preview window
function M.hide_preview()
  -- Cancel any pending preview generation
  state.preview_cancelled = true
  
  -- Reset cancellation flag after a short delay
  vim.defer_fn(function()
    state.preview_cancelled = false
  end, 50)
  
  if state.preview_winid and vim.api.nvim_win_is_valid(state.preview_winid) then
    vim.api.nvim_win_close(state.preview_winid, true)
    state.preview_winid = nil
  end
end

-- Get buffer state at specific event index
function M.get_buffer_state_at_event(event_index)
  local session = storage.get_session()
  local events = session.events or {}
  
  if #events == 0 then
    return nil, nil, nil
  end
  
  -- Check cache first
  local cache_key = tostring(event_index)
  if state.cached_buffer_states[cache_key] then
    local cached = state.cached_buffer_states[cache_key]
    return cached.lines, cached.event_line, cached.buf_name
  end
  
  -- Get initial state
  local bufnr = state.active_bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    for _, ev in ipairs(events) do
      if ev.buf then
        bufnr = ev.buf
        break
      end
    end
  end
  
  if not bufnr then
    return nil, nil, nil
  end
  
  local initial_state = storage.get_initial_state(bufnr)
  if not initial_state then
    return nil, nil, nil
  end
  
  local lines = {}
  for i, line in ipairs(initial_state) do
    lines[i] = line
  end
  
  local target_event = events[event_index]
  local event_line = 1
  local buf_name = ""
  
  -- Apply events up to target
  for i = 1, math.min(event_index, #events) do
    local ev = events[i]
    if ev.buf == bufnr and ev.kind ~= 'segment' then
      -- Apply the edit
      local after_lines = {}
      if ev.after and ev.after ~= "" then
        after_lines = vim.split(ev.after, "\n", true)
      end
      
      local start_line = ev.lnum - 1
      local end_line = ev.lastline
      
      -- Remove old lines and insert new ones
      for j = end_line, start_line + 1, -1 do
        table.remove(lines, j)
      end
      
      for j, new_line in ipairs(after_lines) do
        table.insert(lines, start_line + j, new_line)
      end
      
      -- Track the event line
      if i == event_index then
        event_line = ev.lnum
        buf_name = ev.bufname or ""
      end
    end
  end
  
  -- Cache result (LRU - respect max_cache_size config)
  local cache_count = 0
  for _ in pairs(state.cached_buffer_states) do cache_count = cache_count + 1 end
  if cache_count >= CONFIG.max_cache_size then
    -- Remove oldest entries instead of clearing all
    local entries = {}
    for k, v in pairs(state.cached_buffer_states) do
      table.insert(entries, {key = k, data = v})
    end
    -- Sort by access (we'll use a simple approach: remove first half)
    table.sort(entries, function(a, b) return a.key < b.key end)
    for i = 1, math.floor(#entries / 2) do
      state.cached_buffer_states[entries[i].key] = nil
    end
  end
  
  state.cached_buffer_states[cache_key] = {
    lines = lines,
    event_line = event_line,
    buf_name = buf_name
  }
  
  return lines, event_line, buf_name
end

-- Highlight drag section
function M.highlight_drag_section(percent)
  if not state.bufnr then return end
  
  -- Clear previous highlights
  vim.api.nvim_buf_clear_namespace(state.bufnr, ns_id, 0, -1)
  
  -- Calculate positions
  local bar_width = state.width - 35
  local layout = state.layout
  bar_width = layout and layout.bar_width or bar_width
  local target_pos = math.floor(percent * bar_width)
  
  -- Highlight from current position to target
  local current_percent = state.total_events > 0 and (state.current_event / state.total_events) or 0
  local current_pos = math.floor(current_percent * bar_width)
  
  local start_pos = math.min(current_pos, target_pos)
  local end_pos = math.max(current_pos, target_pos)
  
  -- Add highlight
  local time_end = 16
  local bar_start = layout and layout.bar_start_0 or (time_end + 2)
  
  vim.api.nvim_buf_add_highlight(state.bufnr, ns_id, 'Visual', 0, 
    bar_start + start_pos, bar_start + end_pos + 1)
end

-- Seek to percentage with debouncing
function M.seek_to_percent(percent)
  -- Edge case: invalid percent
  if type(percent) ~= "number" or percent ~= percent then
    return
  end
  
  percent = clamp_percent(percent)
  
  -- Cancel existing seek timer
  if state.seek_timer then
    pcall(vim.fn.timer_stop, state.seek_timer)
  end
  
  -- Store pending seek
  state.pending_seek = percent
  
  -- Debounce rapid seek operations
  state.seek_timer = vim.defer_fn(function()
    if state.pending_seek ~= percent then
      return  -- Another seek was queued
    end
    state.pending_seek = nil
    state.seek_timer = nil
    
    -- Perform the actual seek
    local ok, replay = pcall(require, 'neoreplay.replay')
    if not ok or not replay or not replay.seek_to_event then
      return
    end
    
    -- Edge case: zero events
    if state.total_events <= 0 then
      return
    end
    
    local event_index = math.floor(percent * state.total_events)
    event_index = math.max(1, math.min(event_index, state.total_events))
    
    local ok2, err = pcall(replay.seek_to_event, event_index)
    if not ok2 then
      vim.notify("NeoReplay: Seek failed: " .. tostring(err), vim.log.levels.DEBUG)
    end
  end, CONFIG.seek_debounce)
end

-- Seek relative (seconds)
function M.seek_relative(seconds)
  -- Approximate events per second
  local events_per_second = 5
  if state.total_time > 0 then
    events_per_second = state.total_events / state.total_time
  end
  
  local event_offset = math.floor(seconds * events_per_second)
  local target_event = state.current_event + event_offset
  target_event = math.max(1, math.min(target_event, state.total_events))
  
  M.seek_to_percent(target_event / state.total_events)
end

function M.destroy()
  -- Cancel any pending seek
  if state.seek_timer then
    pcall(vim.fn.timer_stop, state.seek_timer)
    state.seek_timer = nil
  end
  
  -- Cancel any async preview
  state.preview_cancelled = true
  
  -- Clean up resize autocmd
  if state.resize_autocmd then
    pcall(vim.api.nvim_del_autocmd, state.resize_autocmd)
    state.resize_autocmd = nil
  end
  
  M.hide_preview()
  
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_win_close(state.winid, true)
  end
  
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    vim.api.nvim_buf_delete(state.bufnr, { force = true })
  end
  
  if state.preview_bufnr and vim.api.nvim_buf_is_valid(state.preview_bufnr) then
    vim.api.nvim_buf_delete(state.preview_bufnr, { force = true })
  end
  
  state = {
    winid = nil,
    bufnr = nil,
    preview_winid = nil,
    preview_bufnr = nil,
    is_dragging = false,
    drag_start_x = nil,
    is_visible = false,
    total_events = 0,
    current_event = 0,
    current_time = 0,
    total_time = 0,
    width = 80,
    cached_buffer_states = {},
    last_preview_update = 0,
    active_bufnr = nil,
    layout = nil,
    seek_timer = nil,
    pending_seek = nil,
    resize_autocmd = nil,
    preview_cancelled = false,
  }
end

-- Check if visible
function M.is_visible()
  return state.is_visible
end

-- Get current state
function M.get_state()
  return {
    current_event = state.current_event,
    total_events = state.total_events,
    current_time = state.current_time,
    total_time = state.total_time,
    percent = state.total_events > 0 and (state.current_event / state.total_events) or 0,
  }
end

return M
