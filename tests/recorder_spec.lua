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
assert(events[1].edit_type ~= nil, "Event should include edit_type")
assert(events[1].kind == 'edit', "Event kind should be edit")

-- Multi-buffer recording
local buf_a = vim.api.nvim_create_buf(true, false)
local buf_b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(buf_a, 0, -1, false, {"A1"})
vim.api.nvim_buf_set_lines(buf_b, 0, -1, false, {"B1"})
vim.api.nvim_set_current_buf(buf_a)

recorder.start({ all_buffers = true })
vim.api.nvim_buf_set_lines(buf_a, 0, 1, false, {"A1 changed"})
vim.api.nvim_buf_set_lines(buf_b, 0, 1, false, {"B1 changed"})
vim.wait(50)
recorder.stop()

local mb_events = storage.get_events()
local seen_a, seen_b = false, false
for _, ev in ipairs(mb_events) do
  if ev.buf == buf_a then seen_a = true end
  if ev.buf == buf_b then seen_b = true end
end
assert(seen_a and seen_b, "Multi-buffer recording should include both buffers")

print("Recorder tests passed!")
