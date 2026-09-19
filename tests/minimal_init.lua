-- Minimal init for headless tests: put the repo on the runtimepath.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(root)
vim.opt.swapfile = false
vim.opt.shadafile = 'NONE'
vim.opt.undofile = false
