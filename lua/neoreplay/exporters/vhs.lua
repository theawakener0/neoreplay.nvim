local storage = require('neoreplay.storage')
local utils = require('neoreplay.utils')
local vhs_themes = require('neoreplay.vhs_themes')

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

local function detect_theme()
  local theme = vim.g.neoreplay_vhs_theme
  if theme then
    local resolved = vhs_themes.resolve(theme)
    if resolved then
      return resolved
    end
    vim.notify("NeoReplay: Unknown VHS theme '" .. theme .. "'. Falling back to auto-detect.", vim.log.levels.WARN)
  end

  local theme_map = {
    ["catppuccin-mocha"] = "Catppuccin Mocha",
    ["catppuccin-frappe"] = "Catppuccin Frappe",
    ["catppuccin-macchiato"] = "Catppuccin Macchiato",
    ["catppuccin-latte"] = "Catppuccin Latte",
    ["tokyonight"] = "Tokyo Night",
    ["nord"] = "Nord",
    ["dracula"] = "Dracula",
    ["gruvbox-dark"] = "Gruvbox Dark",
    ["gruvbox-light"] = "Gruvbox Light",
    ["monokai"] = "Monokai",
  }
  local user_mappings = vim.g.neoreplay_vhs_mappings or {}
  for k, v in pairs(user_mappings) do
    theme_map[k:lower()] = v
  end

  local current_colorscheme = vim.g.colors_name or ""
  theme = theme_map[current_colorscheme:lower()] or "Catppuccin Frappe"
  return vhs_themes.resolve(theme) or theme
end

function M.export(opts)
  local session = storage.get_session()
  if not session or #session.events == 0 then
    vim.notify("NeoReplay: No session recorded to export.", vim.log.levels.WARN)
    return false
  end

  local format = opts.format or "gif"
  local speed = opts.speed or 20.0
  local quality = opts.quality or 100
  local filename = opts.filename or ("neoreplay." .. format)
  local theme = detect_theme()

  local base_dir = vim.fn.expand('~/.neoreplay')
  vim.fn.mkdir(base_dir, 'p')
  local json_path = opts.json_path or (base_dir .. '/vhs_session.json')
  local tape_path = opts.tape_path or (base_dir .. '/neoreplay.tape')
  local root = plugin_root()
  local rtp = vim.fn.fnameescape(root)
  local init_path = resolve_init_path(opts)
  local nvim_cmd = init_path and ("nvim -u " .. vim.fn.shellescape(init_path)) or "nvim -u NONE"

  local data = vim.fn.json_encode(session)
  local f = io.open(json_path, "w")
  if f then f:write(data) f:close() end

  local duration = 5
  if #session.events > 1 then
    duration = (session.events[#session.events].timestamp - session.events[1].timestamp) / speed
  end
  duration = math.ceil(duration) + 2

  local meta = string.format("# NeoReplay %s | speed=%.1f | buffers=%d", format:upper(), speed, vim.tbl_count(session.buffers or {}))

  local tape = {
    meta,
    'Output ' .. filename,
    'Set FontSize 16',
    'Set Width 1200',
    'Set Height 800',
    'Set Padding 20',
    'Set Theme "' .. theme .. '"',
    format == "mp4" and 'Set Quality ' .. quality or '',
    'Hide',
    "Type `" .. nvim_cmd .. " -c 'set runtimepath+=" .. rtp .. "' -c 'lua require(\"neoreplay\").load_session(\"" .. json_path .. "\")' -c 'lua require(\"neoreplay\").play({ speed = " .. speed .. " })'`",
    'Enter',
    'Sleep 1s',
    'Show',
    'Sleep ' .. duration .. 's',
    'Type "q"',
    'Sleep 500ms',
  }

  local tf = io.open(tape_path, "w")
  if tf then
    tf:write(table.concat(tape, "\n"))
    tf:close()
    vim.notify(string.format("NeoReplay: Tape for %s generated at %s. (Speed: %.1fx). Run `vhs < %s`", format:upper(), tape_path, speed, tape_path), vim.log.levels.INFO)
  end

  return true
end

function M.list_themes()
  return vhs_themes.all
end

function M.available()
  return utils.detect_command('vhs')
end

return M
