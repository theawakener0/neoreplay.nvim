local chronos = require('neoreplay.chronos')
local storage = require('neoreplay.storage')

-- Force undolevels and write to ensure history is captured
vim.o.undolevels = 1000
vim.o.undofile = true

-- Setup a buffer with history
local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(bufnr)

-- Initial state
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {"Base line"})
local tmpfile = vim.fn.tempname() .. "_chronos_test.txt"
vim.cmd("silent! write! " .. tmpfile)

-- Sequence of edits to generate undotree
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {"Step 1"})
vim.wait(10)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {"Step 2"})
vim.wait(10)

-- Go back and create a fork
vim.cmd("undo 1")
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {"Step 2 Alternate"})

-- Final check of history
local ut = vim.fn.undotree()
print("History entries found: " .. #ut.entries)

print("Starting Chronos Excavation...")
chronos.excavate(bufnr, { force = true })

local events = storage.get_events()
local final_state = storage.get_final_state(bufnr) or {}

local function assert_eq(a, b, msg)
  if a ~= b then error(string.format("%s: %s != %s", msg or "Assertion failed", tostring(a), tostring(b))) end
end

if #events == 0 then
  print("Error: No events captured by Chronos.")
  os.exit(1)
end

local has_segment = false
for _, ev in ipairs(events) do
  if ev.kind == 'segment' then
    has_segment = true
    break
  end
end
if not has_segment then
  print("Warning: No segment markers found; undo tree may not have branches.")
end

print("Captured " .. #events .. " events")
print("Final state: " .. (final_state[1] or "N/A"))

assert_eq(final_state[1], "Step 2 Alternate", "Final state mismatch")

print("Chronos Excavation tests passed!")

-- Cleanup temp file and any swap
pcall(vim.fn.delete, tmpfile)
pcall(vim.fn.delete, tmpfile .. ".swp")
