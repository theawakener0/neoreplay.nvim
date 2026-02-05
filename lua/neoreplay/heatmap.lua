local M = {}

-- Configuration
local CONFIG = {
    max_lines = 10000,      -- Skip for huge files
    update_interval = 250,  -- ms between updates (increased for stability)
    max_levels = 10,        -- Intensity levels
    enabled = false,
}

-- State
local edit_data = {}       -- { [bufnr] = { [line] = count } }
local ns_id = vim.api.nvim_create_namespace('neoreplay_heatmap')
local last_update = 0

-- Color gradient from blue (cold) to red (hot)
local HEAT_COLORS = {
    [1]  = "#1e3a5f", -- Cold blue
    [2]  = "#1e40af",
    [3]  = "#1e3a8a",
    [4]  = "#172554",
    [5]  = "#2d5016", -- Greenish transition
    [6]  = "#3f6212",
    [7]  = "#b7791f", -- Yellow/Orange
    [8]  = "#92400e",
    [9]  = "#991b1b", -- Hot red
    [10] = "#c53030", -- Peak intensity
}

function M.setup_highlights()
    for i, color in pairs(HEAT_COLORS) do
        vim.api.nvim_set_hl(0, 'NeoReplayHeat' .. i, { bg = color, default = true })
    end
end

---Track a line edit
---@param bufnr number
---@param lnum number 1-indexed line number
function M.record(bufnr, lnum)
    if not CONFIG.enabled then return end
    
    -- Skip huge files
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if line_count > CONFIG.max_lines then return end
    
    if not edit_data[bufnr] then
        edit_data[bufnr] = {}
    end
    
    edit_data[bufnr][lnum] = (edit_data[bufnr][lnum] or 0) + 1
end

---Render heatmap highlights
---@param bufnr number
function M.render(bufnr)
    if not CONFIG.enabled then
        M.clear(bufnr)
        return
    end
    
    -- Throttle updates
    local now = vim.loop.now()
    if now - last_update < CONFIG.update_interval then
        return
    end
    last_update = now
    
    local data = edit_data[bufnr]
    if not data then return end
    
    -- Calculate max for normalization
    local max_edits = 0
    for _, count in pairs(data) do
        max_edits = math.max(max_edits, count)
    end
    
    if max_edits == 0 then return end
    
    -- Clear and redraw
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
    M.setup_highlights()
    
    -- Batch extmark creation for performance
    pcall(function()
        for line, count in pairs(data) do
            local intensity = math.min(CONFIG.max_levels, 
                math.floor((count / max_edits) * CONFIG.max_levels))
            
            if intensity > 0 then
                vim.api.nvim_buf_set_extmark(bufnr, ns_id, line - 1, 0, {
                    line_hl_group = 'NeoReplayHeat' .. intensity,
                    priority = 100,
                })
            end
        end
    end)
end

function M.clear(bufnr)
    if bufnr then
        edit_data[bufnr] = nil
        if vim.api.nvim_buf_is_valid(bufnr) then
          pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_id, 0, -1)
        end
    else
        edit_data = {}
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_valid(b) then
            pcall(vim.api.nvim_buf_clear_namespace, b, ns_id, 0, -1)
          end
        end
    end
end

function M.toggle()
    CONFIG.enabled = not CONFIG.enabled
    if not CONFIG.enabled then
        M.clear()
    end
    vim.notify(CONFIG.enabled and "NeoReplay: Heat map enabled" or "NeoReplay: Heat map disabled")
    return CONFIG.enabled
end

function M.is_enabled()
  return CONFIG.enabled
end

---Calculate heat map for a specific session (compatibility)
function M.calculate(session)
  local heat = {}
  local max_count = 0

  for _, event in ipairs(session.events) do
    local bufnr = event.bufnr or event.buf
    if bufnr and event.lnum then
      heat[bufnr] = heat[bufnr] or {}
      local start_line = event.lnum
      local end_line = event.lastline or event.lnum
      
      for l = start_line, end_line do
        heat[bufnr][l] = (heat[bufnr][l] or 0) + 1
        max_count = math.max(max_count, heat[bufnr][l])
      end
    end
  end

  local intensity = {}
  if max_count == 0 then return intensity end

  for bufnr, lines in pairs(heat) do
    intensity[bufnr] = {}
    for line, count in pairs(lines) do
      intensity[bufnr][line] = math.min(10, math.ceil((count / max_count) * 10))
    end
  end

  return intensity
end

return M
