local utils = require('neoreplay.utils')
local vhs_themes = require('neoreplay.vhs_themes')

local M = {}

-- Active jobs tracking for timeout management
local active_jobs = {}
local JOB_TIMEOUT_MS = 30000 -- 30 seconds timeout

-- Progress tracking
local progress_message = ""
local stop_progress

local function start_progress(message)
  stop_progress()
  progress_message = message or ""
  progress_index = 1
  progress_active = true
  vim.notify("NeoReplay: " .. progress_message, vim.log.levels.INFO)
end

stop_progress = function()
  progress_message = ""
end

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
    use_user = (vim.g.neoreplay_export_use_user_config ~= false)
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
  theme = theme_map[current_colorscheme:lower()]
  
  -- Warn user if theme not found
  if not theme and current_colorscheme ~= "" then
    vim.notify(string.format("NeoReplay: Theme '%s' not mapped, using default. " ..
      "Add to neoreplay_vhs_mappings for custom themes.", current_colorscheme), 
      vim.log.levels.WARN)
  end
  
  theme = theme or "Catppuccin Mocha"
  return vhs_themes.resolve(theme) or theme
end

-- Calculate dimensions based on content
local function calculate_dimensions(lines, font_size)
  font_size = font_size or 16
  
  local line_count = #lines
  if line_count == 0 then
    line_count = 1
  end
  
  -- Find longest line
  local max_line_length = 0
  for _, line in ipairs(lines) do
    -- Account for tab width (assume 4 spaces)
    local expanded = line:gsub("\t", string.rep(" ", 4))
    max_line_length = math.max(max_line_length, #expanded)
  end
  
  -- Estimate character width (approximate based on font)
  local char_width = font_size * 0.6
  local padding = 40
  local min_width = 400
  local max_width = 1920
  local width = math.min(max_width, math.max(min_width, max_line_length * char_width + padding * 2))
  
  -- Calculate height with better formula
  local line_height = font_size * 1.5
  local header_height = 40
  local footer_height = 20
  local height = line_count * line_height + header_height + footer_height + padding
  local min_height = 200
  local max_height = 1080
  height = math.min(max_height, math.max(min_height, height))
  
  return math.floor(width), math.floor(height)
end

-- Validate input lines
local function validate_lines(lines)
  if not lines then
    return false, "No lines provided"
  end
  if type(lines) ~= "table" then
    return false, "Lines must be a table"
  end
  if #lines == 0 then
    return false, "No content to snapshot (empty selection)"
  end
  
  -- Check for file size limit (1000 lines)
  local MAX_LINES = 1000
  if #lines > MAX_LINES then
    return false, string.format("Content too large (%d lines, max %d). " ..
      "Select a smaller range.", #lines, MAX_LINES)
  end
  
  -- Check for empty or whitespace-only content
  local has_content = false
  for _, line in ipairs(lines) do
    if line and line:match("%S") then
      has_content = true
      break
    end
  end
  if not has_content then
    return false, "No content to snapshot (only whitespace)"
  end
  
  return true, nil
end

-- Write file with proper error handling
local function write_file(path, content)
  local f, err = io.open(path, "w")
  if not f then
    return false, string.format("Failed to open file '%s': %s", path, err or "unknown error")
  end
  
  local success, write_err = pcall(function()
    f:write(content)
    f:close()
  end)
  
  if not success then
    return false, string.format("Failed to write file '%s': %s", path, write_err)
  end
  
  return true, nil
end

local function copy_file(src, dest)
  local rf, rerr = io.open(src, "rb")
  if not rf then
    return false, string.format("Failed to open source '%s': %s", src, rerr or "unknown error")
  end
  local wf, werr = io.open(dest, "wb")
  if not wf then
    rf:close()
    return false, string.format("Failed to open destination '%s': %s", dest, werr or "unknown error")
  end
  local ok, err = pcall(function()
    wf:write(rf:read("*all"))
    rf:close()
    wf:close()
  end)
  if not ok then
    return false, string.format("Failed to copy file: %s", err)
  end
  return true, nil
end

local function find_latest_frame(dir, format)
  if vim.fn.isdirectory(dir) ~= 1 then
    return nil
  end
  local files = vim.fn.readdir(dir)
  if not files or #files == 0 then
    return nil
  end
  local ext = "." .. format
  local candidates = {}
  for _, name in ipairs(files) do
    if name:sub(-#ext) == ext then
      table.insert(candidates, name)
    end
  end
  if #candidates == 0 then
    return nil
  end
  table.sort(candidates)
  return dir .. "/" .. candidates[#candidates]
end

-- Cleanup temp directory
local function cleanup(tmp_dir)
  vim.fn.delete(tmp_dir, "rf")
end

-- Setup timeout for a job
local function setup_timeout(job_id, tmp_dir, job_name)
  local timer = vim.loop.new_timer()
  timer:start(JOB_TIMEOUT_MS, 0, vim.schedule_wrap(function()
    if active_jobs[job_id] then
      stop_progress()
      vim.fn.jobstop(job_id)
      cleanup(tmp_dir)
      vim.notify(string.format("NeoReplay: %s timed out after %d seconds", 
        job_name, JOB_TIMEOUT_MS / 1000), vim.log.levels.ERROR)
      active_jobs[job_id] = nil
    end
    timer:close()
  end))
  return timer
end

function M.export(lines, opts)
  opts = opts or {}
  
  -- Validate input
  local valid, err_msg = validate_lines(lines)
  if not valid then
    vim.notify("NeoReplay: " .. err_msg, vim.log.levels.ERROR)
    return
  end
  
  local format = (opts.format or "png"):lower()
  if format == "jpeg" then format = "jpg" end
  if format ~= "png" and format ~= "jpg" then
    vim.notify("NeoReplay: Unsupported format for snap. Use png or jpg.", vim.log.levels.ERROR)
    return
  end
  local font_size = opts.font_size or 16
  local theme = detect_theme()
  local filename = opts.name or utils.get_timestamp_filename(format)
  if filename and not filename:match("%.[%w]+$") then
    filename = filename .. "." .. format
  end
  local snap_dir = vim.g.neoreplay_snap_dir or vim.fn.expand("~/.neoreplay/snaps/")
  if not snap_dir:match("/$") then snap_dir = snap_dir .. "/" end
  
  -- Ensure snap directory exists
  local dir_ok, dir_err = pcall(utils.ensure_dir, snap_dir)
  if not dir_ok then
    vim.notify("NeoReplay: Failed to create snap directory: " .. tostring(dir_err), vim.log.levels.ERROR)
    return
  end
  
  local output_path = snap_dir .. filename
  
  -- Use unique temp directory for this snapshot
  local tmp_dir = vim.fn.expand("~/.neoreplay/tmp_snap_" .. os.time() .. "_" .. math.random(1000, 9999))
  local mkdir_ok, mkdir_err = pcall(vim.fn.mkdir, tmp_dir, "p")
  if not mkdir_ok then
    vim.notify("NeoReplay: Failed to create temp directory: " .. tostring(mkdir_err), vim.log.levels.ERROR)
    return
  end
  
  local code_path = tmp_dir .. "/code" .. (opts.ext or "")
  local tape_path = tmp_dir .. "/snap.tape"
  local frames_dir = tmp_dir .. "/frames"
  vim.fn.mkdir(frames_dir, "p")
  
  -- Write lines to temp file
  local content = table.concat(lines, "\n")
  local write_ok, write_err = write_file(code_path, content)
  if not write_ok then
    cleanup(tmp_dir)
    vim.notify("NeoReplay: " .. write_err, vim.log.levels.ERROR)
    return
  end
  
  -- Calculate dynamic dimensions
  local width, height = calculate_dimensions(lines, font_size)
  
  local root = plugin_root()
  local rtp = vim.fn.fnameescape(root)
  local init_path = resolve_init_path(opts)
  local nvim_cmd = init_path and ("nvim -u " .. vim.fn.shellescape(init_path)) or "nvim -u NONE"
  
  local tape = {
    'Output "' .. frames_dir .. '"',
    'Set FontSize ' .. font_size,
    'Set Width ' .. width,
    'Set Height ' .. height,
    'Set Padding 20',
    'Set Theme "' .. theme .. '"',
    'Hide',
    "Type `" .. nvim_cmd .. " -c 'set runtimepath+=" .. rtp .. "' " .. vim.fn.shellescape(code_path) .. "`",
    'Enter',
    'Sleep 500ms',
    'Show',
    'Sleep 1s',
  }
  
  -- Write tape file
  local tape_ok, tape_err = write_file(tape_path, table.concat(tape, "\n"))
  if not tape_ok then
    cleanup(tmp_dir)
    vim.notify("NeoReplay: " .. tape_err, vim.log.levels.ERROR)
    return
  end
  
  -- Start progress indicator
  start_progress("Capturing code snapshot")
  
  -- Capture stderr for error reporting
  local stderr_output = {}
  
  local vhs_job_id = vim.fn.jobstart({"vhs", tape_path}, {
    stderr_buffered = true,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            table.insert(stderr_output, line)
          end
        end
      end
    end,
    on_exit = function(job_id, exit_code)
      -- Clear timeout
      if job_id then
        active_jobs[job_id] = nil
      end
      
      if exit_code ~= 0 then
        stop_progress()
        cleanup(tmp_dir)
        local err_detail = table.concat(stderr_output, "\n")
        vim.notify(string.format("NeoReplay: VHS failed (exit %d). %s", 
          exit_code, err_detail ~= "" and "Error: " .. err_detail or ""), 
          vim.log.levels.ERROR)
        return
      end
      
      if vim.fn.filereadable(output_path) ~= 1 then
        local latest_frame = find_latest_frame(frames_dir, format)
        if not latest_frame then
          stop_progress()
          cleanup(tmp_dir)
          vim.notify("NeoReplay: VHS did not produce any frames", vim.log.levels.ERROR)
          return
        end
        local copy_ok, copy_err = copy_file(latest_frame, output_path)
        if not copy_ok then
          stop_progress()
          cleanup(tmp_dir)
          vim.notify("NeoReplay: Failed to save snapshot: " .. copy_err, vim.log.levels.ERROR)
          return
        end
      end

      stop_progress()
      vim.notify("NeoReplay: Snapshot saved to " .. output_path, vim.log.levels.INFO)

      if opts.clipboard then
        local ok, err = utils.copy_to_clipboard(output_path)
        if ok then
          vim.notify("NeoReplay: Copied to clipboard.", vim.log.levels.INFO)
        else
          vim.notify("NeoReplay: Clipboard failed: " .. (err or "unknown"), vim.log.levels.ERROR)
        end
      end

      cleanup(tmp_dir)
    end
  })
  
  if vhs_job_id and vhs_job_id > 0 then
    active_jobs[vhs_job_id] = true
    setup_timeout(vhs_job_id, tmp_dir, "VHS")
  else
    stop_progress()
    cleanup(tmp_dir)
    vim.notify("NeoReplay: Failed to start VHS", vim.log.levels.ERROR)
  end
end

function M.available()
  return utils.detect_command('vhs')
end

return M
