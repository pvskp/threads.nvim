-- threads.nvim: floating input prompt for new comments and replies
local config = require('threads.config')

local M = {}

--- Open a floating input window.
--- opts = { title, initial, footer, height, on_submit(lines), on_cancel() }
function M.prompt(opts)
  opts = opts or {}
  local cfg = config.get().input or {}

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'threads-input'
  local initial = opts.initial or ''
  local lines = initial == '' and { '' } or vim.split(initial, '\n', { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local width = math.max(math.floor(vim.o.columns * (cfg.width or 0.6)), 30)
  width = math.min(width, math.max(vim.o.columns - 4, 20))
  local height = opts.height or math.max(#lines + 1, cfg.height or 4)
  height = math.min(height, math.max(math.floor(vim.o.lines * 0.6), 3))
  local row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0)
  local col = math.max(math.floor((vim.o.columns - width) / 2), 0)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = row,
    col = col,
    width = width,
    height = height,
    style = 'minimal',
    border = cfg.border or 'rounded',
    title = ' ' .. (opts.title or 'Threads') .. ' ',
    title_pos = 'center',
    footer = opts.footer or ' <C-s> submit · <Esc> cancel ',
    footer_pos = 'center',
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].scrolloff = 0
  vim.wo[win].winhighlight = table.concat({
    'NormalFloat:Normal',
    'FloatBorder:ThreadsBorder',
    'FloatTitle:ThreadsTitle',
    'FloatFooter:ThreadsMuted',
    'CursorLine:Visual',
  }, ',')

  local closed = false
  local function finish(submit)
    if closed then
      return
    end
    closed = true
    local content
    if submit then
      content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    end
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    vim.schedule(function()
      if submit then
        if opts.on_submit then
          opts.on_submit(content)
        end
      elseif opts.on_cancel then
        opts.on_cancel()
      end
    end)
  end

  local map = vim.keymap.set
  map({ 'i', 'n' }, '<C-s>', function()
    finish(true)
  end, { buffer = buf, nowait = true, silent = true, desc = 'submit' })
  map('n', '<CR>', function()
    finish(true)
  end, { buffer = buf, nowait = true, silent = true, desc = 'submit' })
  map('n', 'q', function()
    finish(false)
  end, { buffer = buf, nowait = true, silent = true, desc = 'cancel' })
  map('i', '<Esc>', function()
    finish(false)
  end, { buffer = buf, nowait = true, silent = true, desc = 'cancel' })

  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win),
    once = true,
    callback = function()
      if closed then
        return
      end
      closed = true
      if opts.on_cancel then
        vim.schedule(opts.on_cancel)
      end
    end,
  })

  vim.schedule(function()
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local last = math.max(#buf_lines, 1)
    vim.api.nvim_win_set_cursor(win, { last, #(buf_lines[last] or '') })
    vim.cmd('startinsert')
  end)

  return { buf = buf, win = win, close = finish }
end

return M
