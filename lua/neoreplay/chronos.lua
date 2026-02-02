local storage = require('neoreplay.storage')

local M = {}

local function get_all_sequences(entries, seqs)
  if not entries then return end
  for _, entry in ipairs(entries) do
    if entry.seq then seqs[entry.seq] = true end
    if entry.alt then get_all_sequences(entry.alt, seqs) end
    -- Note: undotree structure depends on nvim version but alt is standard
  end
end

function M.excavate(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ut = vim.fn.undotree()
  if not ut.entries or #ut.entries == 0 then
    vim.notify("NeoReplay Chronos: No undo history found.", vim.log.levels.WARN)
    return nil
  end

  -- 1. Create a temporary undo file
  local tmp_undo = os.tmpname()
  local ok, err = pcall(function()
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd('wundo! ' .. tmp_undo)
    end)
  end)

  if not ok then
    vim.notify("NeoReplay Chronos: Failed to write temporary undo file. " .. tostring(err), vim.log.levels.ERROR)
    return nil
  end

  -- 2. Setup a hidden "Shadow Buffer"
  -- Create a new unlisted scratch buffer
  local scratch = vim.api.nvim_create_buf(false, true)
  
  -- Use a pcall block for the main excavation to ensure cleanup
  local events = {}
  local success, exc_err = pcall(function()
    -- Initialize scratch buffer with current content
    -- (Though we'll undo back to 0 immediately)
    local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, current_lines)
    
    -- Load history into scratch
    vim.api.nvim_buf_call(scratch, function()
      vim.cmd('rundo ' .. tmp_undo)
    end)

    -- 3. Gather and Sort Sequences
    local seq_map = { [0] = true }
    get_all_sequences(ut.entries, seq_map)
    local sorted_seqs = {}
    for seq in pairs(seq_map) do table.insert(sorted_seqs, seq) end
    table.sort(sorted_seqs)

    -- 4. Excavate
    local cache = {}
    
    -- Capability: deep copy cache without unpack limit
    local function copy_cache(tbl)
      local copy = {}
      for i, v in ipairs(tbl) do copy[i] = v end
      return copy
    end

    -- Go to start (seq 0)
    vim.api.nvim_buf_call(scratch, function()
      vim.cmd('noautocmd undo 0')
      cache = vim.api.nvim_buf_get_lines(scratch, 0, -1, false)
    end)

    -- Capture initial state for storage
    local initial_state = copy_cache(cache)

    -- Attach listener to scratch buffer
    -- We'll collect raw changes
    local raw_events = {}
    local current_timestamp = 1000.0 -- Synthetic start time

    vim.api.nvim_buf_attach(scratch, false, {
      on_lines = function(_, _, _, first, last, new_last)
        -- 'before' lines from our current cache
        local before_lines = {}
        for i = first + 1, last do
          table.insert(before_lines, cache[i] or "")
        end
        local before_text = table.concat(before_lines, "\n")

        -- Update cache efficiently in-place
        local scratch_lines = vim.api.nvim_buf_get_lines(scratch, first, new_last, false)
        local diff = #scratch_lines - (last - first)
        if diff ~= 0 then
          table.move(cache, last + 1, #cache, first + #scratch_lines + 1)
          if diff < 0 then
            for i = #cache + diff + 1, #cache do cache[i] = nil end
          end
        end
        for i, line in ipairs(scratch_lines) do
          cache[first + i] = line
        end

        table.insert(raw_events, {
          timestamp = current_timestamp,
          buf = bufnr, -- Report original bufnr
          before = before_text,
          after = table.concat(scratch_lines, "\n"),
          lnum = first + 1,
          lastline = last,
          new_lastline = new_last
        })
        current_timestamp = current_timestamp + 0.1 -- Synthetic gap
      end
    })

    -- Traverse forward through all sequences
    vim.api.nvim_buf_call(scratch, function()
      for _, seq in ipairs(sorted_seqs) do
        if seq > 0 then
          vim.cmd('noautocmd undo ' .. seq)
        end
      end
      -- Ensure we capture the absolute final state after all transitions
      cache = vim.api.nvim_buf_get_lines(scratch, 0, -1, false)
    end)

    -- Persist into storage for replay/consumers
    if not storage.is_active() then
      storage.start()
    end
    local initial_copy = {}
    for i, v in ipairs(initial_state) do initial_copy[i] = v end
    storage.set_initial_state(bufnr, initial_copy)

    for _, ev in ipairs(raw_events) do
      storage.add_event(ev)
    end

    local final_copy = {}
    for i, v in ipairs(cache) do final_copy[i] = v end
    storage.set_final_state(bufnr, final_copy)

    events = {
      initial_state = initial_copy,
      raw_events = raw_events,
      final_state = final_copy
    }
  end)

  -- Cleanup
  if os.date("%s", 0) ~= "0" then -- simple check if os.remove is safe
    os.remove(tmp_undo)
  end
  vim.api.nvim_buf_delete(scratch, { force = true })

  if not success then
    vim.notify("NeoReplay Chronos: Excavation error: " .. tostring(exc_err), vim.log.levels.ERROR)
    return nil
  end

  return events
end

return M
