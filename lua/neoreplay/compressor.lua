local M = {}

-- Pre-allocate string buffer capacity
local STRING_BUFFER_CAPACITY = 100

function M.compress(events)
  if #events == 0 then return {} end

  local compressed = {}
  local current_group = nil
  local string_buffer = {}
  
  -- Pre-fill string buffer with nils
  for i = 1, STRING_BUFFER_CAPACITY do
    string_buffer[i] = nil
  end

  for _, event in ipairs(events) do
    if event.kind == 'segment' then
      if current_group then
        table.insert(compressed, current_group)
        current_group = nil
      end
      table.insert(compressed, {
        kind = 'segment',
        label = event.label or 'Segment',
        timestamp = event.timestamp,
        bufnr = event.bufnr or event.buf,
      })
      goto continue
    end

    -- Early exit: check for obvious boundaries first
    local is_boundary = false
    
    -- Structural boundary: multi-line changes
    if not is_boundary and event.lastline and event.lnum then
      local lines_affected = event.lastline - (event.lnum - 1)
      if lines_affected > 1 then
        is_boundary = true
      end
    end
    
    -- Blank line boundaries
    if not is_boundary then
      local after_blank = event.after and event.after:match("^%s*$")
      local before_blank = event.before and event.before:match("^%s*$")
      if after_blank or before_blank then
        is_boundary = true
      end
    end

    if not current_group then
      -- Start new group
      local after_lines = {}
      if event.after and event.after ~= "" then
        -- Use string buffer for splitting (more efficient)
        after_lines = vim.split(event.after, "\n", true)
      end
      current_group = {
        bufnr = event.bufnr or event.buf,
        lnum = event.lnum,
        lastline = event.lastline,
        start_time = event.timestamp,
        end_time = event.timestamp,
        before = event.before,
        after = event.after,
        after_lines = after_lines,
        bufname = event.bufname,
        filetype = event.filetype,
        edit_type = event.edit_type,
        lines_changed = event.lines_changed,
        kind = event.kind or 'edit'
      }
    else
      local time_diff = event.timestamp - current_group.end_time
      local same_buffer = (event.bufnr or event.buf) == current_group.bufnr
      local same_range = event.lnum == current_group.lnum and event.lastline == current_group.lastline
      
      -- Check structural boundary using pre-computed flag
      local structural_boundary = is_boundary

      if same_buffer and same_range and time_diff < 2.0 and not structural_boundary then
        -- Merge into current group
        current_group.after = event.after
        if event.after == "" then
          current_group.after_lines = {}
        else
          current_group.after_lines = vim.split(event.after, "\n", true)
        end
        current_group.end_time = event.timestamp
      else
        -- Close current group and start new one
        table.insert(compressed, current_group)
        
        local after_lines = {}
        if event.after and event.after ~= "" then
          after_lines = vim.split(event.after, "\n", true)
        end
        current_group = {
          bufnr = event.bufnr or event.buf,
          lnum = event.lnum,
          lastline = event.lastline,
          start_time = event.timestamp,
          end_time = event.timestamp,
          before = event.before,
          after = event.after,
          after_lines = after_lines,
          bufname = event.bufname,
          filetype = event.filetype,
          edit_type = event.edit_type,
          lines_changed = event.lines_changed,
          kind = event.kind or 'edit'
        }
      end
    end

    ::continue::
  end

  if current_group then
    table.insert(compressed, current_group)
  end

  return compressed
end

-- Fast path for single-buffer compression
function M.compress_single_buffer(events, bufnr)
  if #events == 0 then return {} end

  local compressed = {}
  local current_group = nil

  for _, event in ipairs(events) do
    if event.buf ~= bufnr then goto continue end
    
    if event.kind == 'segment' then
      if current_group then
        table.insert(compressed, current_group)
        current_group = nil
      end
      table.insert(compressed, {
        kind = 'segment',
        label = event.label or 'Segment',
        timestamp = event.timestamp,
        buf = event.buf,
      })
      goto continue
    end

    -- Fast boundary check
    local is_boundary = false
    if event.lastline and event.lnum then
      if event.lastline - (event.lnum - 1) > 1 then
        is_boundary = true
      end
    end

    local after_blank = event.after and event.after:match("^%s*$")
    local before_blank = event.before and event.before:match("^%s*$")

    if not is_boundary and (after_blank or before_blank) then
      is_boundary = true
    end

    if not current_group then
      current_group = {
        buf = event.buf,
        lnum = event.lnum,
        lastline = event.lastline,
        start_time = event.timestamp,
        end_time = event.timestamp,
        before = event.before,
        after = event.after,
        after_lines = event.after ~= "" and vim.split(event.after, "\n", true) or {},
        bufname = event.bufname,
        filetype = event.filetype,
        edit_type = event.edit_type,
        lines_changed = event.lines_changed,
        kind = event.kind or 'edit'
      }
    else
      local time_diff = event.timestamp - current_group.end_time
      local same_range = event.lnum == current_group.lnum and event.lastline == current_group.lastline
      
      if same_range and time_diff < 2.0 and not is_boundary then
        current_group.after = event.after
        current_group.after_lines = event.after ~= "" and vim.split(event.after, "\n", true) or {}
        current_group.end_time = event.timestamp
      else
        table.insert(compressed, current_group)
        current_group = {
          buf = event.buf,
          lnum = event.lnum,
          lastline = event.lastline,
          start_time = event.timestamp,
          end_time = event.timestamp,
          before = event.before,
          after = event.after,
          after_lines = event.after ~= "" and vim.split(event.after, "\n", true) or {},
          bufname = event.bufname,
          filetype = event.filetype,
          edit_type = event.edit_type,
          lines_changed = event.lines_changed,
          kind = event.kind or 'edit'
        }
      end
    end

    ::continue::
  end

  if current_group then
    table.insert(compressed, current_group)
  end

  return compressed
end

return M
