-- threads.nvim: conventional plugin entry point.
--
-- Commands are defined in lua/threads/commands.lua and registered here and by
-- require('threads').setup(), so they work even with a late 'runtimepath' add.
if vim.g.loaded_threads_nvim then
  return
end
vim.g.loaded_threads_nvim = true

if vim.fn.has('nvim-0.10') ~= 1 then
  vim.notify('threads.nvim requires Neovim >= 0.10', vim.log.levels.ERROR)
  return
end

require('threads.commands').register()
require('threads')._ensure()
