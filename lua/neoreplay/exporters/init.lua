local M = { exporters = {} }

function M.register(name, exporter)
  M.exporters[name] = exporter
end

function M.list()
  local names = {}
  for name, _ in pairs(M.exporters) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

function M.get(name)
  return M.exporters[name]
end

function M.export(name, opts)
  local exporter = M.get(name)
  if not exporter then
    vim.notify("NeoReplay: Exporter not found: " .. tostring(name), vim.log.levels.ERROR)
    return false
  end
  return exporter.export(opts or {})
end

return M
