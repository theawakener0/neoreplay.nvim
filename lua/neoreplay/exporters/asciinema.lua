local storage = require('neoreplay.storage')
local utils = require('neoreplay.utils')

local M = {}

local function write_file(path, content)
  local f = io.open(path, 'w')
  if not f then return false end
  f:write(content)
  f:close()
  return true
end

function M.export(opts)
  local session = storage.get_session()
  if not session or #session.events == 0 then
    vim.notify("NeoReplay: No session recorded to export.", vim.log.levels.WARN)
    return false
  end

  local base_dir = vim.fn.expand('~/.neoreplay')
  vim.fn.mkdir(base_dir, 'p')
  local out_path = opts.filename or (base_dir .. '/neoreplay.cast')
  local json_path = opts.json_path or (base_dir .. '/asciinema_session.json')
  local speed = opts.speed or 20.0

  local data = vim.fn.json_encode(session)
  write_file(json_path, data)

  local script = [[#!/usr/bin/env bash
set -euo pipefail
if ! command -v asciinema >/dev/null 2>&1; then
  echo "asciinema not installed"
  exit 1
fi
asciinema rec --quiet --overwrite -c "nvim -u NONE -c 'set runtimepath+=.' -c 'lua require(\"neoreplay\").load_session(\"]] .. json_path .. [[\")' -c 'lua require(\"neoreplay\").play({ speed = ]] .. speed .. [[ })'" ]] .. out_path .. [[
]]

  local script_path = opts.script or (base_dir .. '/neoreplay_asciinema.sh')
  write_file(script_path, script)
  vim.fn.system({ 'chmod', '+x', script_path })

  vim.notify("NeoReplay: Asciinema script generated at " .. script_path, vim.log.levels.INFO)
  return true
end

function M.available()
  return utils.detect_command('asciinema')
end

return M
