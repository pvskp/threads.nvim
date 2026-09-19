-- threads.nvim: :checkhealth threads
local M = {}

function M.check()
  local health = vim.health
  health.start('threads.nvim')

  if vim.fn.has('nvim-0.10') == 1 then
    health.ok('Neovim >= 0.10')
  else
    health.error('Neovim >= 0.10 is required')
  end

  local config = require('threads.config')
  local cfg = config.get()

  local dir = cfg.storage.dir
  if vim.fn.isdirectory(dir) == 1 then
    health.ok('storage directory: ' .. dir)
  else
    health.warn('storage directory will be created on first save: ' .. dir)
  end

  local agent = require('threads.agent')
  local spec = agent.resolve()
  if spec then
    health.ok('agent: ' .. spec.name .. '  [' .. table.concat(spec.cmd, ' ') .. '] (mode=' .. spec.mode .. ')')
  else
    health.error('no agent command configured or found on PATH. Set agent.cmd in setup().')
  end

  local store = require('threads.store')
  local ok, files = pcall(store.files)
  if ok then
    health.info(('thread files on disk: %d'):format(#files))
  end
end

return M
