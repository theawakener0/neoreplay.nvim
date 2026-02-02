local recorder = require('neoreplay.recorder')
local storage = require('neoreplay.storage')

local function assert_true(cond, msg)
  if not cond then error(msg or 'Assertion failed') end
end

-- Setup two buffers
local buf1 = vim.api.nvim_create_buf(true, false)
local buf2 = vim.api.nvim_create_buf(true, false)

vim.api.nvim_buf_set_lines(buf1, 0, -1, false, {"alpha"})
vim.api.nvim_buf_set_lines(buf2, 0, -1, false, {"beta"})

vim.api.nvim_set_current_buf(buf1)
recorder.start({ all_buffers = true })

-- Edit buffer 1
vim.api.nvim_buf_set_lines(buf1, 0, 1, false, {"alpha-1"})
vim.wait(20)
-- Edit buffer 2
vim.api.nvim_buf_set_lines(buf2, 0, 1, false, {"beta-1"})
vim.wait(20)

recorder.stop()

local session = storage.get_session()
local events = session.events or {}

local has_buf1 = false
local has_buf2 = false
for _, ev in ipairs(events) do
  if ev.buf == buf1 then has_buf1 = true end
  if ev.buf == buf2 then has_buf2 = true end
end

assert_true(has_buf1, 'Should have events for buffer 1')
assert_true(has_buf2, 'Should have events for buffer 2')

local final1 = storage.get_final_state(buf1)
local final2 = storage.get_final_state(buf2)
assert_true(final1 and final1[1] == 'alpha-1', 'Final state for buffer 1 mismatch')
assert_true(final2 and final2[1] == 'beta-1', 'Final state for buffer 2 mismatch')

local meta1 = storage.get_buffer_meta(buf1) or {}
local meta2 = storage.get_buffer_meta(buf2) or {}
assert_true(meta1.filetype ~= nil, 'Buffer 1 metadata missing')
assert_true(meta2.filetype ~= nil, 'Buffer 2 metadata missing')

local index = session.index or {}
assert_true(index.total_events and index.total_events >= 2, 'Index total_events should be set')
assert_true(index.by_buf and index.by_buf[buf1] and index.by_buf[buf2], 'Index by_buf should include both buffers')

print('Multi-buffer recording tests passed!')
