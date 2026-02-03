local storage = require('neoreplay.storage')
local utils = require('neoreplay.utils')

local M = {}

local function plugin_root()
  local source = debug.getinfo(1, "S").source
  if not source then return "." end
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  return vim.fn.fnamemodify(source, ":h:h:h:h")
end

local function resolve_init_path(opts)
  local init = opts.nvim_init or vim.g.neoreplay_export_nvim_init
  local use_user = opts.use_user_config
  if use_user == nil then
    use_user = vim.g.neoreplay_export_use_user_config
  end
  if not init and use_user then
    init = vim.fn.expand("$MYVIMRC")
    if not init or init == "" then
      local candidate = vim.fn.stdpath("config") .. "/init.lua"
      if vim.loop.fs_stat(candidate) then
        init = candidate
      end
    end
  end
  return init
end

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
  local root = plugin_root()
  local rtp = vim.fn.fnameescape(root)
  local init_path = resolve_init_path(opts)
  local nvim_cmd = init_path and ("nvim -u " .. vim.fn.shellescape(init_path)) or "nvim -u NONE"

  local data = vim.fn.json_encode(session)
  write_file(json_path, data)

  local script = [[#!/usr/bin/env bash
set -euo pipefail
if ! command -v asciinema >/dev/null 2>&1; then
  echo "asciinema not installed"
  exit 1
fi
asciinema rec --quiet --overwrite -c "" .. nvim_cmd .. " -c 'set runtimepath+=" .. rtp .. "' -c 'lua require(\"neoreplay\").load_session(\"]] .. json_path .. [[\")' -c 'lua require(\"neoreplay\").play({ speed = ]] .. speed .. [[ })'" ]] .. out_path .. [[
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
