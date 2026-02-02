local neoreplay = require('neoreplay')
local storage = require('neoreplay.storage')
local exporters = require('neoreplay.exporters')
local vhs = require('neoreplay.exporters.vhs')
local frames = require('neoreplay.exporters.frames')
local asciinema = require('neoreplay.exporters.asciinema')

local function assert_ok(cond, msg)
  if not cond then error(msg or "Assertion failed") end
end

local function read_file(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local content = f:read('*all')
  f:close()
  return content
end

-- Prepare a tiny session
local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {"one"})

storage.start()
storage.set_initial_state(bufnr, {"one"})
storage.set_buffer_meta(bufnr, { name = "test.lua", filetype = "lua" })
storage.add_event({
  timestamp = 1.0,
  buf = bufnr,
  before = "one",
  after = "two",
  lnum = 1,
  lastline = 1,
  new_lastline = 1,
  edit_type = "replace",
  kind = 'edit'
})
storage.set_final_state(bufnr, {"two"})
storage.stop()

-- Ensure registry works
assert_ok(exporters.get('frames') ~= nil, "Frames exporter should be registered")

-- Export frames to temp dir
local dir = vim.fn.tempname()
frames.export({ dir = dir })
local meta = vim.fn.filereadable(dir .. '/metadata.json') == 1
assert_ok(meta, "metadata.json should exist")
assert_ok(vim.fn.filereadable(dir .. '/frame_000001.json') == 1, "frame_000001.json should exist")

-- VHS exporter (no external tool execution)
local vhs_json = vim.fn.tempname() .. '.json'
local vhs_tape = vim.fn.tempname() .. '.tape'
local ok = vhs.export({ format = 'gif', json_path = vhs_json, tape_path = vhs_tape, filename = 'out.gif' })
assert_ok(ok == true, "VHS export should return true")
assert_ok(vim.fn.filereadable(vhs_json) == 1, "VHS json should exist")
assert_ok(vim.fn.filereadable(vhs_tape) == 1, "VHS tape should exist")

-- Asciinema exporter (script generation only)
local cast_path = vim.fn.tempname() .. '.cast'
local script_path = vim.fn.tempname() .. '.sh'
local json_path = vim.fn.tempname() .. '.json'
local ok2 = asciinema.export({ filename = cast_path, script = script_path, json_path = json_path })
assert_ok(ok2 == true, "Asciinema export should return true")
assert_ok(vim.fn.filereadable(script_path) == 1, "Asciinema script should exist")
local script_content = read_file(script_path) or ""
assert_ok(script_content:find("asciinema rec", 1, true) ~= nil, "Script should contain asciinema command")

print("Exporters tests passed!")
