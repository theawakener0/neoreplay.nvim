local recorder = require('neoreplay.recorder')
local storage = require('neoreplay.storage')

-- Setup
local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(bufnr)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {"line 1", "line 2"})

recorder.start()

-- Simulate edits
vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {"line 1 changed"})
vim.wait(100)
vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, {"line 2 modified"})

recorder.stop()

local events = storage.get_events()

-- Assertion helper
local function assert(cond, msg)
  if not cond then error(msg or "Assertion failed") end
end

assert(#events >= 2, "Should have recorded at least 2 events, got " .. #events)
assert(events[1].after == "line 1 changed", "First event should match first change")
assert(events[2].after == "line 2 modified", "Second event should match second change")

print("Recorder tests passed!")
