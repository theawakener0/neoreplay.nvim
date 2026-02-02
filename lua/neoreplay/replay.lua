local storage = require('neoreplay.storage')
local ui = require('neoreplay.ui')
local compressor = require('neoreplay.compressor')
local M = {}

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
local progress_update_interval = 10
local max_events_per_tick = 100
local max_tick_ms = 6
local adaptive_batching = true
local last_tick_ms = 0
local cadence_window = { count = 0, start_time = 0 }

local function apply_event(event)
  if event.kind == 'segment' then
    if replay_winid then
      ui.set_annotation(replay_winid, event.label or 'Segment')
    end
    return
  end

  local buf = target_buf_map[event.buf] or target_bufnr
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  vim.api.nvim_buf_set_lines(buf, event.lnum - 1, event.lastline, false, event.after_lines or {})

  local winid = replay_win_map[event.buf] or replay_winid
  if winid and vim.api.nvim_win_is_valid(winid) then
    pcall(vim.api.nvim_win_set_cursor, winid, {math.min(event.lnum, vim.api.nvim_buf_line_count(buf)), 0})
  else
    pcall(vim.api.nvim_win_set_cursor, 0, {math.min(event.lnum, vim.api.nvim_buf_line_count(buf)), 0})
  end
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
  progress_update_interval = opts.progress_update_interval or 10
  if progress_update_interval < 1 then
    progress_update_interval = 10
  end
  max_events_per_tick = opts.max_events_per_tick or 100
  if max_events_per_tick < 1 then
    max_events_per_tick = 100
  end
  max_tick_ms = opts.max_tick_ms or 6
  if max_tick_ms < 1 then
    max_tick_ms = 6
  end
  adaptive_batching = opts.adaptive_batching ~= false
  last_tick_ms = 0
  
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
    vim.api.nvim_win_set_config(winid, { title = " " .. opts.title .. " " })
  end

  -- Set initial state
  for _, original_bufnr in ipairs(bufs) do
    local initial_state = storage.get_initial_state(original_bufnr)
    local target = target_buf_map[original_bufnr]
    if initial_state and target then
      vim.api.nvim_buf_set_lines(target, 0, -1, false, initial_state)
    end
  end

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

  while is_playing and current_event_index <= #playback_events do
    local event = playback_events[current_event_index]
    apply_event(event)
    last_event = event

    cadence_window.count = cadence_window.count + 1

    if current_event_index % progress_update_interval == 0 then
      local progress = math.floor((current_event_index / #playback_events) * 100)
      if progress ~= last_progress then
        local elapsed = math.max((vim.loop.now() - cadence_window.start_time) / 1000, 0.001)
        local rate = cadence_window.count / elapsed
        local label = ""
        if event.kind ~= 'segment' then
          label = string.format("%s • %s", event.edit_type or "edit", event.lines_changed and (tostring(event.lines_changed) .. " lines") or "")
        end
        local annotation = string.format("%d%% | %.1f ev/s | %s", progress, rate, label)
        ui.set_annotation(replay_winid, annotation)
        last_progress = progress
      end
    end

    current_event_index = current_event_index + 1
    processed = processed + 1
    if processed >= max_events_per_tick or (vim.loop.now() - start_ms) >= max_tick_ms then
      break
    end

    local next_event = playback_events[current_event_index]
    if next_event then
      local delay = (next_event.start_time - event.end_time) / playback_speed
      if delay >= 0.02 then
        break
      end
    end
  end

  if not is_playing then return end

  if current_event_index > #playback_events then
    M.stop_playback()
    M.validate_and_finish()
    return
  end

  local next_event = playback_events[current_event_index]
  local delay = 0.02
  if last_event and next_event then
    delay = (next_event.start_time - last_event.end_time) / playback_speed
    if delay < 0.02 then delay = 0.02 end
  end

  last_tick_ms = vim.loop.now() - start_ms
  if adaptive_batching then
    if last_tick_ms > max_tick_ms then
      max_events_per_tick = math.max(10, math.floor(max_events_per_tick * 0.8))
    elseif last_tick_ms < (max_tick_ms * 0.5) then
      max_events_per_tick = math.min(500, math.floor(max_events_per_tick * 1.2))
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
    vim.notify("NeoReplay: Replay finished with 100% fidelity.", vim.log.levels.INFO)
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
  replay_winid = nil
  target_bufnr = nil
  target_buf_map = {}
  replay_win_map = {}
end

function M.set_speed(speed)
  playback_speed = speed
end

return M
