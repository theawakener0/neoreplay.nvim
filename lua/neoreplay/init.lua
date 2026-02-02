local recorder = require('neoreplay.recorder')
local replay = require('neoreplay.replay')
local storage = require('neoreplay.storage')

local M = {}

function M.start()
  recorder.start()
  print("NeoReplay: Started recording.")
end

function M.stop()
  recorder.stop()
  print("NeoReplay: Stopped recording.")
end

function M.play()
  replay.play()
end

function M.export()
  local session = storage.get_session()
  local data = vim.fn.json_encode(session)
  local path = vim.fn.expand('~/neoreplay_session.json')
  local f = io.open(path, "w")
  if f then
    f:write(data)
    f:close()
    print("NeoReplay: Session exported to " .. path)
  else
    print("NeoReplay: Failed to export session.")
  end
end

function M.setup(opts)
  -- Placeholder for future config
  if opts and opts.ignore_whitespace ~= nil then
    vim.g.neoreplay_ignore_whitespace = opts.ignore_whitespace
  end
end

return M
