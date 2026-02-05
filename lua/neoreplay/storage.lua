local M = {}

local session = {
  active = false,
  start_time = 0,
  events = {},
  initial_state = {}, -- bufnr -> content
  final_state = {},   -- bufnr -> content
  buffers = {},       -- bufnr -> metadata
  index = {           -- lightweight index for tooling
    by_buf = {},
    total_events = 0,
  },
  metadata = {},      -- session-level metadata
  
  -- Performance tracking
  stats = {
    events_compressed = 0,
    memory_saved = 0,
    last_gc_count = 0,
  }
}

-- Memory optimization: deduplicate strings
local string_cache = {}
local function dedup_string(s)
  if not s or s == "" then return s end
  local cached = string_cache[s]
  if cached then return cached end
  -- Only cache shorter strings to avoid memory bloat
  if #s < 1000 then
    string_cache[s] = s
  end
  return s
end

-- Clear string cache periodically to prevent unbounded growth
function M.clear_string_cache()
  string_cache = {}
  session.stats.memory_saved = 0
end

function M.start()
  session.active = true
  session.start_time = vim.loop.hrtime() / 1e9
  session.events = {}
  session.initial_state = {}
  session.final_state = {}
  session.buffers = {}
  session.index = { by_buf = {}, total_events = 0 }
  session.metadata = {}
  session.stats = { events_compressed = 0, memory_saved = 0, last_gc_count = 0 }
  string_cache = {}
end

function M.stop()
  session.active = false
  -- Force garbage collection of string cache
  string_cache = {}
end

function M.is_active()
  return session.active
end

function M.add_event(event)
  if not session.active then return end
  
  -- Memory optimization: deduplicate text content
  if event.before then
    event.before = dedup_string(event.before)
  end
  if event.after then
    event.after = dedup_string(event.after)
  end
  if event.bufname then
    event.bufname = dedup_string(event.bufname)
  end
  
  table.insert(session.events, event)
  session.index.total_events = session.index.total_events + 1
  local new_index = session.index.total_events
  local bufnr = event.bufnr or event.buf
  if bufnr then
    session.index.by_buf[bufnr] = (session.index.by_buf[bufnr] or 0) + 1
  end
  
  -- Periodic cache cleanup (every 500 events)
  if session.index.total_events % 500 == 0 and session.index.total_events > 0 then
    -- Keep cache size manageable
    local cache_size = 0
    for _ in pairs(string_cache) do cache_size = cache_size + 1 end
    if cache_size > 5000 then
      M.clear_string_cache()
    end
  end
  return new_index
end

function M.get_events()
  return session.events
end

function M.set_initial_state(bufnr, content)
  -- Make deep copy to prevent reference issues
  local copy = {}
  for i, line in ipairs(content) do
    copy[i] = dedup_string(line)
  end
  session.initial_state[bufnr] = copy
end

function M.get_initial_state(bufnr)
  return session.initial_state[bufnr]
end

function M.set_final_state(bufnr, content)
  -- Make deep copy
  local copy = {}
  for i, line in ipairs(content) do
    copy[i] = dedup_string(line)
  end
  session.final_state[bufnr] = copy
end

function M.set_buffer_meta(bufnr, meta)
  session.buffers[bufnr] = {
    name = dedup_string(meta.name),
    filetype = meta.filetype or '',
  }
end

function M.get_buffer_meta(bufnr)
  return session.buffers[bufnr]
end

function M.set_metadata(meta)
  session.metadata = meta or {}
end

function M.get_metadata()
  return session.metadata or {}
end

function M.get_final_state(bufnr)
  return session.final_state[bufnr]
end

function M.get_session()
  return session
end

function M.load_session(data)
  session.events = data.events or {}
  session.initial_state = data.initial_state or {}
  session.final_state = data.final_state or {}
  session.buffers = data.buffers or {}
  session.index = data.index or { by_buf = {}, total_events = #session.events }
  session.metadata = data.metadata or {}
  session.start_time = data.start_time or 0
  session.active = false
  
  -- Re-deduplicate loaded strings
  string_cache = {}
end

function M.load_chronos_session(bufnr, data)
  session.active = false
  session.events = data.raw_events
  
  -- Deep copy with deduplication
  local initial_copy = {}
  for i, v in ipairs(data.initial_state or {}) do
    initial_copy[i] = dedup_string(v)
  end
  session.initial_state = { [bufnr] = initial_copy }
  
  local final_copy = {}
  for i, v in ipairs(data.final_state or {}) do
    final_copy[i] = dedup_string(v)
  end
  session.final_state = { [bufnr] = final_copy }
  
  session.buffers = { [bufnr] = data.buffer_meta or {} }
  session.index = data.index or { by_buf = { [bufnr] = #data.raw_events }, total_events = #data.raw_events }
  session.metadata = data.metadata or {}
  session.start_time = 0
end

-- Get memory statistics
function M.get_stats()
  local cache_size = 0
  for _ in pairs(string_cache) do cache_size = cache_size + 1 end
  return {
    events = session.index.total_events,
    string_cache_size = cache_size,
    buffers = vim.tbl_count(session.buffers),
    memory_active = session.active,
  }
end

return M
