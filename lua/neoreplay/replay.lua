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

function M.play()
  if is_playing then return end
  
  local session = storage.get_session()
  local events = session.events
  if #events == 0 then
    print("No events to replay")
    return
  end

  playback_events = compressor.compress(events)
  current_event_index = 1
  is_playing = true
  
  -- Create floating window
  local bufnr, winid = ui.create_replay_window()
  target_bufnr = bufnr

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
  vim.api.nvim_win_set_cursor(0, {math.min(event.lnum, vim.api.nvim_buf_line_count(target_bufnr)), 0})

  current_event_index = current_event_index + 1
  
  if next_event then
    local delay = (next_event.start_time - event.end_time) / playback_speed
    if delay < 0.05 then delay = 0.05 end -- Minimum perceptible delay
    
    playback_timer = vim.defer_fn(function()
      M.schedule_next()
    end, math.floor(delay * 1000))
  else
    M.stop_playback()
    M.validate_and_finish()
  end
end

function M.toggle_pause()
  is_playing = not is_playing
  if is_playing then
    print("NeoReplay: Resumed")
    M.schedule_next()
  else
    print("NeoReplay: Paused")
  end
end

function M.speed_up()
  playback_speed = math.min(playback_speed * 1.5, 100.0)
  print(string.format("NeoReplay Speed: %.1fx", playback_speed))
end

function M.speed_down()
  playback_speed = math.max(playback_speed / 1.5, 1.0)
  print(string.format("NeoReplay Speed: %.1fx", playback_speed))
end

function M.stop_playback()
  is_playing = false
  if playback_timer then
    -- Timer will check is_playing on next tick
  end
end
end

function M.stop_playback()
  is_playing = false
  if playback_timer then
    -- defer_fn doesn't have a simple cancel in Neovim Lua API easily 
    -- but we check is_playing in schedule_next
  end
end

function M.set_speed(speed)
  playback_speed = speed
end

return M
