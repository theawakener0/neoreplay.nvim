local storage = require('neoreplay.storage')
local recorder = require('neoreplay.recorder')
local replay = require('neoreplay.replay')

-- Setup
local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(bufnr)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {"Line A"})

recorder.start()
vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {"Line A modified"})
vim.wait(50)
vim.api.nvim_buf_set_lines(bufnr, 1, 1, false, {"Line B added"})
vim.wait(50)
recorder.stop()

-- We can't easily test the floating window and timers in headless mode 
-- without mocking the whole UI and vim.defer_fn.
-- But we can verify the storage has captured the states correctly.

local session = storage.get_session()
local initial = storage.get_initial_state(bufnr)
local final = storage.get_final_state(bufnr)

local function assert(cond, msg)
  if not cond then error(msg or "Assertion failed") end
end

local ok, err = pcall(function()
  assert(initial[1] == "Line A", "Initial state incorrect")
  assert(final[1] == "Line A modified", "Final state line 1 incorrect")
  assert(final[2] == "Line B added", "Final state line 2 incorrect")
end)

if not ok then
  print("Test failed: " .. tostring(err))
else
  print("Replay/Fidelity data tests passed!")
end
