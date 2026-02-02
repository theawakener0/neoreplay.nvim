local M = {}

function M.compress(events)
  if #events == 0 then return {} end

  local compressed = {}
  local current_group = nil

  for _, event in ipairs(events) do
    if not current_group then
      current_group = {
        buf = event.buf,
        lnum = event.lnum,
        lastline = event.lastline,
        start_time = event.timestamp,
        end_time = event.timestamp,
        before = event.before,
        after = event.after
      }
    else
      local time_diff = event.timestamp - current_group.end_time
      local same_buffer = event.buf == current_group.buf
      local same_range = event.lnum == current_group.lnum and event.lastline == current_group.lastline
      
      -- Structural boundary heuristic
      local structural_boundary = false
      -- If multiple lines changed in one event, it's likely a significant structural change (paste/delete block)
      if event.lastline - (event.lnum - 1) > 1 or event.after:find("\n") then
        structural_boundary = true
      end
      -- Blank lines are boundaries
      if event.after:match("^%s*$") or event.before:match("^%s*$") then
        structural_boundary = true
      end

      if same_buffer and same_range and time_diff < 2.0 and not structural_boundary then
        -- Merge into current group
        current_group.after = event.after
        current_group.end_time = event.timestamp
      else
        -- Close current group and start new one
        table.insert(compressed, current_group)
        current_group = {
          buf = event.buf,
          lnum = event.lnum,
          lastline = event.lastline,
          start_time = event.timestamp,
          end_time = event.timestamp,
          before = event.before,
          after = event.after
        }
      end
    end
  end

  if current_group then
    table.insert(compressed, current_group)
  end

  return compressed
end

return M
