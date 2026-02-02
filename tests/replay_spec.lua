local recorder = require('neoreplay.recorder')
local storage = require('neoreplay.storage')

-- Setup
local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(bufnr)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {"Line A"})

-- recorder.start() calls storage.start() internally
recorder.start()

-- First edit
vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {"Line A modified"})
vim.wait(100)
-- Second edit
vim.api.nvim_buf_set_lines(bufnr, 1, 1, false, {"Line B added"})
vim.wait(100)

recorder.stop()

local events = storage.get_events()
local initial = storage.get_initial_state(bufnr)
local final = storage.get_final_state(bufnr)

local function assert_eq(a, b, msg)
  if tostring(a) ~= tostring(b) then 
    error(string.format("%s: '%s' != '%s'", msg or "Assertion failed", tostring(a), tostring(b))) 
  end
end

assert_eq(initial[1], "Line A", "Initial mismatch")
assert_eq(final[1], "Line A modified", "Final L1 mismatch")
assert_eq(final[2], "Line B added", "Final L2 mismatch")
if #events < 2 then error("Captured only " .. #events .. " events") end

print("Replay/Fidelity data tests passed!")
