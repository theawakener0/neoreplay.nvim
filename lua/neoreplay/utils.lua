local M = {}

function M.is_real_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return false end
  if vim.api.nvim_buf_get_option(bufnr, 'buftype') ~= '' then return false end
  if not vim.api.nvim_buf_get_option(bufnr, 'modifiable') then return false end
  return true
end

function M.list_recordable_buffers()
  local buffers = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if M.is_real_buffer(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      table.insert(buffers, bufnr)
    end
  end
  return buffers
end

function M.detect_command(cmd)
  return vim.fn.executable(cmd) == 1
end

function M.get_buffer_meta(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return {} end
  return {
    name = vim.api.nvim_buf_get_name(bufnr),
    filetype = vim.api.nvim_buf_get_option(bufnr, 'filetype') or '',
  }
end

function M.edit_type(before_text, after_text)
  if before_text == '' and after_text ~= '' then
    return 'insert'
  end
  if before_text ~= '' and after_text == '' then
    return 'delete'
  end
  if before_text ~= '' and after_text ~= '' then
    return 'replace'
  end
  return 'noop'
end

return M
