local M = {}

local session = {
  active = false,
  start_time = 0,
  events = {},
  initial_state = {}, -- bufnr -> content
  final_state = {},   -- bufnr -> content
}

function M.start()
  session.active = true
  session.start_time = vim.loop.hrtime() / 1e9
  session.events = {}
  session.initial_state = {}
  session.final_state = {}
end

function M.stop()
  session.active = false
end

function M.is_active()
  return session.active
end

function M.add_event(event)
  if not session.active then return end
  table.insert(session.events, event)
end

function M.get_events()
  return session.events
end

function M.set_initial_state(bufnr, content)
  session.initial_state[bufnr] = content
end

function M.get_initial_state(bufnr)
  return session.initial_state[bufnr]
end

function M.set_final_state(bufnr, content)
  session.final_state[bufnr] = content
end

function M.get_final_state(bufnr)
  return session.final_state[bufnr]
end

function M.get_session()
  return session
end

return M
