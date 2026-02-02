local storage = require('neoreplay.storage')

local M = {}

local function ensure_dir(path)
  vim.fn.mkdir(path, 'p')
end

local function write_file(path, content)
  local f = io.open(path, 'w')
  if not f then return false end
  f:write(content)
  f:close()
  return true
end

function M.export(opts)
  local session = storage.get_session()
  if not session or #session.events == 0 then
    vim.notify("NeoReplay: No session recorded to export.", vim.log.levels.WARN)
    return false
  end

  local out_dir = opts.dir or vim.fn.expand('~/.neoreplay/frames')
  ensure_dir(out_dir)

  local buffers = {}
  for bufnr, lines in pairs(session.initial_state or {}) do
    local copy = {}
    for i, line in ipairs(lines) do copy[i] = line end
    buffers[bufnr] = copy
  end

  local meta = {
    format = 'frames',
    total_events = #session.events,
    buffers = session.buffers or {},
  }
  write_file(out_dir .. '/metadata.json', vim.fn.json_encode(meta))

  local frame_index = 1
  for _, event in ipairs(session.events) do
    if event.kind ~= 'segment' then
      local buf = buffers[event.buf]
      if buf then
        local after_lines = {}
        if event.after and event.after ~= '' then
          after_lines = vim.split(event.after, "\n", true)
        end
        local start = event.lnum
        local finish = event.lastline
        local removed = finish - start + 1
        if removed < 0 then removed = 0 end

        local diff = #after_lines - removed
        if diff ~= 0 then
          table.move(buf, finish + 1, #buf, start + #after_lines)
          if diff < 0 then
            for i = #buf + diff + 1, #buf do
              buf[i] = nil
            end
          end
        end
        for i, line in ipairs(after_lines) do
          buf[start + i - 1] = line
        end
      end
    end

    local snapshot = {}
    for bufnr, lines in pairs(buffers) do
      snapshot[bufnr] = table.concat(lines, "\n")
    end
    local payload = {
      index = frame_index,
      timestamp = event.timestamp,
      kind = event.kind or 'edit',
      label = event.label,
      buffers = snapshot,
    }
    write_file(string.format('%s/frame_%06d.json', out_dir, frame_index), vim.fn.json_encode(payload))
    frame_index = frame_index + 1
  end

  vim.notify("NeoReplay: Frames exported to " .. out_dir, vim.log.levels.INFO)
  return true
end

return M
