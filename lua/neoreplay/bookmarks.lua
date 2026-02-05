local storage = require('neoreplay.storage')
local M = {}

local MAX_BOOKMARKS = 50

function M.get_all()
  local session = storage.get_session()
  if not session.metadata.bookmarks then
    session.metadata.bookmarks = {}
  end
  return session.metadata.bookmarks
end

function M.add(label, opts)
  opts = opts or {}
  local bookmarks = M.get_all()
  
  if #bookmarks >= MAX_BOOKMARKS then
    vim.notify("NeoReplay: Maximum bookmarks reached (50)", vim.log.levels.WARN)
    return nil
  end
  
  local session = storage.get_session()
  
  -- Calculate event index
  local event_index = opts.event_index
  if not event_index then
    local replay = require('neoreplay.replay')
    event_index = replay.get_current_index() or #session.events
  end
  
  local event = session.events[event_index] or {}
  
  local bookmark = {
    id = #bookmarks + 1,
    label = label or ("Bookmark " .. (#bookmarks + 1)),
    event_index = event_index,
    timestamp = event.timestamp or os.time(),
    bufnr = event.bufnr or event.buf,
    lnum = event.lnum,
    preview = opts.preview or (event.after_lines and event.after_lines[1] or ""),
    created_at = os.time(),
  }
  
  table.insert(bookmarks, bookmark)
  vim.notify(string.format("NeoReplay: Bookmark added: %s", bookmark.label))
  return bookmark
end

function M.clear()
  local session = storage.get_session()
  session.metadata.bookmarks = {}
  vim.notify("NeoReplay: All bookmarks cleared")
end

function M.jump_to(index)
  local bookmarks = M.get_all()
  local b = bookmarks[index]
  if not b then
    vim.notify("NeoReplay: Bookmark not found", vim.log.levels.ERROR)
    return
  end
  
  local replay = require('neoreplay.replay')
  replay.seek_to_event(b.event_index)
  vim.notify(string.format("NeoReplay: Jumped to %s", b.label))
end

function M.smart_track(event, index)
  -- Heuristic: function/class keywords or large additions
  local important = false
  local label = "Interest"
  
  if event.after_lines and #event.after_lines > 0 then
    local first_line = event.after_lines[1]
    if first_line:match("function") or first_line:match("class") or first_line:match("M%.") then
      important = true
      label = first_line:match("^%s*(.-)%s*$")
    elseif #event.after_lines > 15 then
      important = true
      label = "Large addition"
    end
  end
  
  if important then
    -- Throttled smart tracking (don't spam automated bookmarks)
    local bookmarks = M.get_all()
    local last = bookmarks[#bookmarks]
    if not last or (index - last.event_index) > 50 then
       M.add("Auto: " .. label:sub(1, 30), { event_index = index, preview = label })
    end
  end
end

function M.list()
  local bookmarks = M.get_all()
  if #bookmarks == 0 then
    vim.notify("NeoReplay: No bookmarks found")
    return
  end
  
  local items = {}
  for i, b in ipairs(bookmarks) do
    table.insert(items, string.format("%d. %s [Event %d]", i, b.label, b.event_index))
  end
  
  vim.ui.select(items, {
    prompt = "Select Bookmark to Jump",
  }, function(_, idx)
    if idx then
      M.jump_to(idx)
    end
  end)
end

return M
