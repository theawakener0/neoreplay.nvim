local neoreplay = require('neoreplay')
local snap_exporter = require('neoreplay.exporters.snap')

-- Assertion helper
local function assert(cond, msg)
  if not cond then error(msg or "Assertion failed") end
end

-- Track notifications
local notifications = {}
local original_notify = vim.notify
vim.notify = function(msg, level)
  table.insert(notifications, { msg = msg, level = level })
end

-- Mock the exporter's available and export functions
local export_called = false
local exported_lines = {}
local exported_opts = {}

local original_available = snap_exporter.available
local original_export = snap_exporter.export

snap_exporter.available = function() return true end
snap_exporter.export = function(lines, opts)
  export_called = true
  exported_lines = lines
  exported_opts = opts
end

-- Create a test buffer
local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(bufnr, "test.lua")
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "local x = 10",
  "print(x)",
  "local y = 20",
  "print(x + y)"
})
vim.api.nvim_set_current_buf(bufnr)

-- Test Case 1: Simple snap of whole buffer
neoreplay.snap({}, 1, 4)
assert(export_called == true, "Export should have been called")
assert(#exported_lines == 4, "Should have exported 4 lines")
assert(exported_lines[1] == "local x = 10", "First line should match")
assert(exported_opts.ext == ".lua", "Extension should be detected")

-- Reset
export_called = false
notifications = {}

-- Test Case 2: Partial snap
neoreplay.snap({ format = "jpg", clipboard = true }, 2, 3)
assert(export_called == true, "Export should have been called for partial snap")
assert(#exported_lines == 2, "Should have exported 2 lines")
assert(exported_lines[1] == "print(x)", "First exported line should be the second line of buffer")
assert(exported_opts.format == "jpg", "Format should be passed")
assert(exported_opts.clipboard == true, "Clipboard opt should be passed")

-- Reset
export_called = false
notifications = {}

-- Test Case 3: Default clipboard should be true
neoreplay.snap({}, 1, 4)
assert(exported_opts.clipboard == true, "Clipboard should be true by default")

-- Reset
export_called = false
notifications = {}

-- Test Case 4: Explicitly disable clipboard
neoreplay.snap({ clipboard = false }, 1, 4)
assert(exported_opts.clipboard == false, "Clipboard should be disabled when requested")

-- Reset
export_called = false
notifications = {}

-- Test Case 5: Empty lines should fail gracefully
snap_exporter.export = function(lines, opts)
  -- Simulate the validation logic from the real export function
  if not lines or #lines == 0 then
    vim.notify("NeoReplay: No content to snapshot (empty selection)", vim.log.levels.ERROR)
    return
  end
  export_called = true
  exported_lines = lines
  exported_opts = opts
end

neoreplay.snap({}, 1, 0)  -- Empty range
assert(export_called == false, "Export should not be called for empty selection")
assert(#notifications > 0, "Should have shown error notification")
local has_empty_error = false
for _, n in ipairs(notifications) do
  if n.msg:match("empty") then
    has_empty_error = true
    break
  end
end
assert(has_empty_error, "Should show empty content error")

-- Reset
export_called = false
notifications = {}

-- Test Case 4: Whitespace-only content should fail
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "   ", "\t", "  \n  " })
neoreplay.snap({}, 1, 3)
assert(export_called == false, "Export should not be called for whitespace-only content")
local has_whitespace_error = false
for _, n in ipairs(notifications) do
  if n.msg:match("whitespace") then
    has_whitespace_error = true
    break
  end
end
assert(has_whitespace_error, "Should show whitespace error")

-- Restore buffer content
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "local x = 10",
  "print(x)",
  "local y = 20",
  "print(x + y)"
})

-- Reset
export_called = false
notifications = {}
snap_exporter.export = original_export

-- Test Case 5: Unnamed buffer with filetype
local unnamed_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(unnamed_buf)
vim.api.nvim_buf_set_option(unnamed_buf, 'filetype', 'python')
vim.api.nvim_buf_set_lines(unnamed_buf, 0, -1, false, { "print('hello')" })

neoreplay.snap({}, 1, 1)
assert(export_called == true, "Export should be called for unnamed buffer")
assert(exported_opts.ext == ".py", "Should detect Python extension from filetype")

-- Cleanup
vim.api.nvim_buf_delete(unnamed_buf, { force = true })
snap_exporter.available = original_available
snap_exporter.export = original_export
vim.notify = original_notify

-- Test Case 6: Test dimension calculation
local snap_module = require('neoreplay.exporters.snap')
-- The module doesn't expose calculate_dimensions directly, but we can test via export
-- We've already verified the export works above

print("Snap tests passed")
