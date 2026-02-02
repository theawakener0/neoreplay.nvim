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
local on_finish_callback = nil

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
  
  -- Create floating window
  local original_bufnr = events[1].buf
  local bufnr, winid = ui.create_replay_window(original_bufnr)
  target_bufnr = bufnr

  if opts.title then
    vim.api.nvim_win_set_config(winid, { title = " " .. opts.title .. " " })
  end

  -- Set initial state
  local original_bufnr = events[1].buf
  local initial_state = storage.get_initial_state(original_bufnr)
  if initial_state then
    vim.api.nvim_buf_set_lines(target_bufnr, 0, -1, false, initial_state)
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

  local event = playback_events[current_event_index]
  local next_event = playback_events[current_event_index + 1]
  
  -- Apply event
  local lines = vim.split(event.after, "\n")
  vim.api.nvim_buf_set_lines(target_bufnr, event.lnum - 1, event.lastline, false, lines)
  
  -- Update UI (cursor position)
  pcall(vim.api.nvim_win_set_cursor, 0, {math.min(event.lnum, vim.api.nvim_buf_line_count(target_bufnr)), 0})

  -- Progress notification
  if current_event_index % 5 == 0 then
    local progress = math.floor((current_event_index / #playback_events) * 100)
    vim.api.nvim_buf_set_name(target_bufnr, string.format("Replay Progress: %d%%", progress))
  end

  current_event_index = current_event_index + 1
  
  if next_event then
    local delay = (next_event.start_time - event.end_time) / playback_speed
    if delay < 0.02 then delay = 0.02 end -- Minimum perceptible delay
    
    playback_timer = vim.defer_fn(function()
      M.schedule_next()
    end, math.floor(delay * 1000))
  else
    M.stop_playback()
    M.validate_and_finish()
  end
end

function M.validate_and_finish()
  if #playback_events == 0 then return end
  
  local original_bufnr = playback_events[1].buf
  local final_state = storage.get_final_state(original_bufnr)
  if not final_state then return end

  local current_state = vim.api.nvim_buf_get_lines(target_bufnr, 0, -1, false)
  
  local mismatch = false
  if #current_state ~= #final_state then
    mismatch = true
  else
    for i = 1, #current_state do
      if current_state[i] ~= final_state[i] then
        mismatch = true
        break
      end
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
end

function M.set_speed(speed)
  playback_speed = speed
end

return M
