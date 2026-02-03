local storage = require('neoreplay.storage')
local ui = require('neoreplay.ui')
local compressor = require('neoreplay.compressor')
local progress_bar = require('neoreplay.progress_bar')
local M = {}

-- Performance configuration
local RENDER_BUDGET_MS = 8  -- Max time per frame (8ms = ~120fps target)
local MIN_DELAY_MS = 16     -- Minimum delay between frames (~60fps cap)
local PROGRESS_UPDATE_INTERVAL = 50  -- Update UI every N events (was 10)
local MAX_EVENTS_PER_TICK = 200    -- Increased from 100
local CURSOR_UPDATE_INTERVAL = 5   -- Update cursor every N events
local WINBAR_UPDATE_DEBOUNCE = 150  -- Debounce winbar updates (ms)

local playback_timer = nil
local playback_speed = 20.0
local is_playing = false
local current_event_index = 1
local playback_events = {}
local target_bufnr = nil
local target_buf_map = {}
local replay_winid = nil
local replay_win_map = {}
local on_finish_callback = nil
local last_progress = nil
local adaptive_batching = true
local last_tick_ms = 0
local cadence_window = { count = 0, start_time = 0 }

-- Frame skipping and double buffering
local pending_cursor_update = nil
local last_winbar_update = 0
local frame_skip_counter = 0
local total_frames_skipped = 0

-- Pre-allocated tables for hot paths
local text_cache = {}

local function apply_event(event, skip_visual)
  if event.kind == 'segment' then
    if replay_winid and not skip_visual then
      ui.set_annotation_debounced(replay_winid, event.label or 'Segment', WINBAR_UPDATE_DEBOUNCE)
    end
    return
  end

  local buf = target_buf_map[event.buf] or target_bufnr
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  -- Use set_text for single-line changes (faster than set_lines)
  if event.after_lines and #event.after_lines == 1 and 
     event.lastline - event.lnum == 0 and not skip_visual then
    local line_idx = event.lnum - 1
    local current_lines = vim.api.nvim_buf_get_lines(buf, line_idx, line_idx + 1, false)
    if current_lines[1] then
      vim.api.nvim_buf_set_text(buf, line_idx, 0, line_idx, #current_lines[1], event.after_lines)
    else
      vim.api.nvim_buf_set_lines(buf, line_idx, line_idx + 1, false, event.after_lines)
    end
  else
    vim.api.nvim_buf_set_lines(buf, event.lnum - 1, event.lastline, false, event.after_lines or {})
  end

  -- Batch cursor updates - queue instead of immediate
  if not skip_visual then
    pending_cursor_update = { buf = buf, lnum = event.lnum, win = replay_win_map[event.buf] or replay_winid }
  end
end

local function flush_cursor_update()
  if not pending_cursor_update then return end
  
  local winid = pending_cursor_update.win
  local buf = pending_cursor_update.buf
  local lnum = pending_cursor_update.lnum
  
  if winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_buf_is_valid(buf) then
    local line_count = vim.api.nvim_buf_line_count(buf)
    pcall(vim.api.nvim_win_set_cursor, winid, {math.min(lnum, line_count), 0})
  elseif vim.api.nvim_buf_is_valid(buf) then
    local line_count = vim.api.nvim_buf_line_count(buf)
    pcall(vim.api.nvim_win_set_cursor, 0, {math.min(lnum, line_count), 0})
  end
  
  pending_cursor_update = nil
end

function M.play(opts)
  if is_playing then return end
  opts = opts or {}
  on_finish_callback = opts.on_finish
  
  local session = storage.get_session()
  local events = session.events
  if #events == 0 then
    vim.notify("NeoReplay: No events to replay. Did you start recording?", vim.log.levels.WARN)
    return
  end

  playback_events = compressor.compress(events)
  current_event_index = 1
  is_playing = true
  playback_speed = opts.speed or vim.g.neoreplay_playback_speed or 20.0
  last_progress = nil
  cadence_window = { count = 0, start_time = vim.loop.now() }
  frame_skip_counter = 0
  total_frames_skipped = 0
  pending_cursor_update = nil
  
  -- Performance tuning from opts
  RENDER_BUDGET_MS = opts.render_budget_ms or RENDER_BUDGET_MS
  MAX_EVENTS_PER_TICK = opts.max_events_per_tick or MAX_EVENTS_PER_TICK
  
  -- Create scene windows
  local bufs = {}
  local seen = {}
  for _, ev in ipairs(playback_events) do
    if ev.buf and not seen[ev.buf] then
      table.insert(bufs, ev.buf)
      seen[ev.buf] = true
    end
  end

  if #bufs == 0 then return end

  local focus_buf = opts.focus_bufnr or bufs[1]
  if #bufs > 1 then
    target_buf_map, replay_win_map = ui.create_scene_windows(bufs, focus_buf)
    target_bufnr = target_buf_map[focus_buf]
    replay_winid = replay_win_map[focus_buf]
  else
    local bufnr, winid = ui.create_replay_window(bufs[1])
    target_bufnr = bufnr
    replay_winid = winid
    target_buf_map = { [bufs[1]] = bufnr }
    replay_win_map = { [bufs[1]] = winid }
  end

  if opts.title then
    vim.api.nvim_win_set_config(replay_winid, { title = " " .. opts.title .. " " })
  end

  -- Set initial state
  for _, original_bufnr in ipairs(bufs) do
    local initial_state = storage.get_initial_state(original_bufnr)
    local target = target_buf_map[original_bufnr]
    if initial_state and target then
      vim.api.nvim_buf_set_lines(target, 0, -1, false, initial_state)
    end
  end

  -- Calculate total time from compressed events
  local total_time = 0
  if #playback_events > 1 then
    local first_event = playback_events[1]
    local last_event = playback_events[#playback_events]
    if first_event and last_event then
      total_time = (last_event.end_time or last_event.timestamp or 0) - 
                   (first_event.start_time or first_event.timestamp or 0)
    end
  end

  -- Create progress bar
  progress_bar.create({
    total_events = #playback_events,
    active_bufnr = focus_buf,
    total_time = total_time,
  })

  M.schedule_next()
end

function M.schedule_next()
  if not is_playing then return end
  
  if current_event_index > #playback_events then
    M.stop_playback()
    M.validate_and_finish()
    return
  end

  local start_ms = vim.loop.now()
  local processed = 0
  local last_event = nil
  local should_skip_visual = false
  local cursor_update_counter = 0

  -- Check if we're behind schedule and need to skip frames
  local behind_schedule = last_tick_ms > RENDER_BUDGET_MS * 1.5
  
  while is_playing and current_event_index <= #playback_events do
    -- Check render budget
    local elapsed = vim.loop.now() - start_ms
    if elapsed >= RENDER_BUDGET_MS then
      break
    end

    -- Adaptive frame skipping when behind
    if behind_schedule and frame_skip_counter < 2 then
      should_skip_visual = true
      frame_skip_counter = frame_skip_counter + 1
      total_frames_skipped = total_frames_skipped + 1
    else
      should_skip_visual = false
      frame_skip_counter = 0
    end

    local event = playback_events[current_event_index]
    apply_event(event, should_skip_visual)
    last_event = event

    cadence_window.count = cadence_window.count + 1
    processed = processed + 1
    cursor_update_counter = cursor_update_counter + 1

    -- Flush cursor update periodically
    if cursor_update_counter >= CURSOR_UPDATE_INTERVAL then
      flush_cursor_update()
      cursor_update_counter = 0
    end

    -- Update progress bar every 10 events
    if current_event_index % 10 == 0 then
      local current_time = 0
      if playback_events[current_event_index] then
        local first_event = playback_events[1]
        local current_evt = playback_events[current_event_index]
        current_time = (current_evt.timestamp or 0) - (first_event.timestamp or 0)
      end
      progress_bar.update(current_event_index, #playback_events, current_time, nil)
    end

    -- Debounced progress update (winbar)
    if current_event_index % PROGRESS_UPDATE_INTERVAL == 0 then
      local now = vim.loop.now()
      if now - last_winbar_update >= WINBAR_UPDATE_DEBOUNCE then
        local progress = math.floor((current_event_index / #playback_events) * 100)
        if progress ~= last_progress then
          local elapsed = math.max((now - cadence_window.start_time) / 1000, 0.001)
          local rate = cadence_window.count / elapsed
          local label = ""
          if event.kind ~= 'segment' then
            label = string.format("%s • %s", event.edit_type or "edit", event.lines_changed and (tostring(event.lines_changed) .. " lines") or "")
          end
          local annotation = string.format("%d%% | %.1f ev/s | %s", progress, rate, label)
          ui.set_annotation_debounced(replay_winid, annotation, WINBAR_UPDATE_DEBOUNCE)
          last_progress = progress
          last_winbar_update = now
          
          -- Reset cadence window
          cadence_window = { count = 0, start_time = now }
        end
      end
    end

    current_event_index = current_event_index + 1

    -- Check hard limits
    if processed >= MAX_EVENTS_PER_TICK then
      break
    end

    -- Check timing for next event
    local next_event = playback_events[current_event_index]
    if next_event then
      local delay = (next_event.start_time - event.end_time) / playback_speed
      if delay >= 0.015 then  -- Was 0.02, tighter threshold
        break
      end
    end
  end

  -- Flush any pending cursor update
  flush_cursor_update()

  if not is_playing then return end

  if current_event_index > #playback_events then
    M.stop_playback()
    M.validate_and_finish()
    return
  end

  local MIN_DELAY_S = 0.016

  local next_event = playback_events[current_event_index]
  local delay = MIN_DELAY_S
  if last_event and next_event then
    delay = (next_event.start_time - last_event.end_time) / playback_speed
    if delay < MIN_DELAY_S then delay = MIN_DELAY_S end
  end

  last_tick_ms = vim.loop.now() - start_ms
  if adaptive_batching then
    if last_tick_ms > RENDER_BUDGET_MS then
      MAX_EVENTS_PER_TICK = math.max(50, math.floor(MAX_EVENTS_PER_TICK * 0.9))
    elseif last_tick_ms < (RENDER_BUDGET_MS * 0.4) then
      MAX_EVENTS_PER_TICK = math.min(400, math.floor(MAX_EVENTS_PER_TICK * 1.1))
    end
  end

  playback_timer = vim.defer_fn(function()
    M.schedule_next()
  end, math.floor(delay * 1000))
end

function M.validate_and_finish()
  if #playback_events == 0 then return end
  local mismatch = false

  for original_bufnr, target in pairs(target_buf_map) do
    local final_state = storage.get_final_state(original_bufnr)
    if final_state and target and vim.api.nvim_buf_is_valid(target) then
      local current_state = vim.api.nvim_buf_get_lines(target, 0, -1, false)
      if #current_state ~= #final_state then
        mismatch = true
        break
      end
      for i = 1, #current_state do
        if current_state[i] ~= final_state[i] then
          mismatch = true
          break
        end
      end
      if mismatch then break end
    end
  end

  if mismatch then
    vim.notify("NeoReplay Fidelity Error: Final buffer does not match original!", vim.log.levels.ERROR)
  else
    vim.notify("NeoReplay: Replay finished with 100% fidelity. (Skipped " .. total_frames_skipped .. " frames for performance)", vim.log.levels.INFO)
  end

  if on_finish_callback then
    on_finish_callback()
    on_finish_callback = nil
  end
end

function M.toggle_pause()
  is_playing = not is_playing
  if is_playing then
    vim.notify("NeoReplay: Playing")
    M.schedule_next()
  else
    vim.notify("NeoReplay: Paused")
  end
end

function M.speed_up()
  playback_speed = math.min(playback_speed * 1.5, 100.0)
  vim.notify(string.format("NeoReplay Speed: %.1fx", playback_speed))
end

function M.speed_down()
  playback_speed = math.max(playback_speed / 1.5, 1.0)
  vim.notify(string.format("NeoReplay Speed: %.1fx", playback_speed))
end

function M.stop_playback()
  is_playing = false
  if playback_timer then
    pcall(vim.fn.timer_stop, playback_timer)
    playback_timer = nil
  end
  for _, winid in pairs(replay_win_map) do
    if winid and vim.api.nvim_win_is_valid(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
    end
  end
  
  -- Destroy progress bar
  progress_bar.destroy()
  
  replay_winid = nil
  target_bufnr = nil
  target_buf_map = {}
  replay_win_map = {}
  pending_cursor_update = nil
end

function M.set_speed(speed)
  playback_speed = speed
end

-- Check if currently playing
function M.is_playing()
  return is_playing
end

-- Seek to specific event index (smooth seeking)
function M.seek_to_event(target_index)
  if not is_playing then return end
  
  target_index = math.max(1, math.min(target_index, #playback_events))
  local direction = target_index > current_event_index and 1 or -1
  local distance = math.abs(target_index - current_event_index)
  
  -- For small jumps: apply events directly
  if distance <= 10 then
    -- Apply events one by one
    while current_event_index ~= target_index do
      local event = playback_events[current_event_index]
      if event then
        apply_event(event, false)
      end
      current_event_index = current_event_index + direction
      
      -- Safety check
      if current_event_index < 1 or current_event_index > #playback_events then
        break
      end
    end
    flush_cursor_update()
    
  else
    -- For large jumps: reset and fast-forward
    -- Reset all buffers to initial state
    for original_bufnr, target in pairs(target_buf_map) do
      local initial_state = storage.get_initial_state(original_bufnr)
      if initial_state and target and vim.api.nvim_buf_is_valid(target) then
        vim.api.nvim_buf_set_lines(target, 0, -1, false, initial_state)
      end
    end
    
    -- Apply events up to target in batches for speed
    current_event_index = 1
    local batch_size = math.max(1, math.floor(distance / 20)) -- Process in ~20 batches
    
    while current_event_index < target_index do
      local end_of_batch = math.min(current_event_index + batch_size, target_index)
      
      -- Apply batch
      for i = current_event_index, end_of_batch do
        local event = playback_events[i]
        if event then
          -- For batch mode, skip cursor updates and UI updates
          apply_event(event, true) -- skip_visual = true for speed
        end
      end
      
      current_event_index = end_of_batch + 1
      
      -- Allow UI to update periodically
      if current_event_index % 50 == 0 then
        vim.cmd('redraw')
      end
    end
    
    -- Final flush with visual updates
    flush_cursor_update()
  end
  
  -- Update progress bar
  local current_time = 0
  if playback_events[current_event_index] and playback_events[1] then
    current_time = playback_events[current_event_index].timestamp - playback_events[1].timestamp
  end
  local total_time = 0
  if playback_events[#playback_events] and playback_events[1] then
    total_time = playback_events[#playback_events].timestamp - playback_events[1].timestamp
  end
  progress_bar.update(current_event_index, #playback_events, current_time, total_time)
end

return M
