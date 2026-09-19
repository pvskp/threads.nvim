-- threads.nvim: interactive history window (closed threads included)
local config = require('threads.config')
local util = require('threads.util')

local M = {}

local function core()
  return require('threads.core')
end

local function thread_line(t)
  local icons = config.get().icons
  local icon = icons[t.state] or '?'
  local n = #(t.messages or {})
  local last = t.messages and t.messages[n]
  local preview = util.preview(last and last.content or '', 60)
  local row = (t.range and t.range.start_row or 0) + 1
  local loc = util.file_label(t.file) .. ':' .. row
  return ('  %s  %-8s %-9s %-34s %2d msg  %s'):format(
    icon,
    t.state,
    t.action == 'apply' and 'apply' or 'ask',
    loc,
    n,
    preview
  )
end

function M.open(opts)
  opts = opts or {}
  local cfg = config.get().history or {}
  local threads = core().list({ all = opts.all, include_closed = true, sort = 'updated' })
  if #threads == 0 then
    util.notify('no threads' .. (opts.all and '' or ' in this buffer'))
    return
  end

  local lines = { ('  Threads (%d)  —  <CR> jump · o show · d delete · q close'):format(#threads), '' }
  local line_map = {}
  for _, t in ipairs(threads) do
    lines[#lines + 1] = thread_line(t)
    line_map[#lines] = t.id
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'threads-history'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local width = math.max(math.floor(vim.o.columns * (cfg.width or 0.85)), 30)
  local height = math.max(math.floor(vim.o.lines * (cfg.height or 0.8)), 5)
  local row = math.max(math.floor((vim.o.lines - height) / 2), 0)
  local col = math.max(math.floor((vim.o.columns - width) / 2), 0)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = row,
    col = col,
    width = width,
    height = height,
    style = 'minimal',
    border = cfg.border or 'rounded',
    title = ' Threads history ',
    title_pos = 'center',
  })
  vim.wo[win].cursorline = true
  vim.wo[win].winhighlight = table.concat({
    'NormalFloat:Normal',
    'FloatBorder:ThreadsBorder',
    'FloatTitle:ThreadsTitle',
    'CursorLine:Visual',
  }, ',')
  vim.api.nvim_win_set_cursor(win, { 3, 0 })

  local function current_id()
    local l = vim.api.nvim_win_get_cursor(win)[1]
    return line_map[l]
  end
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  vim.keymap.set('n', 'q', close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set('n', '<CR>', function()
    local id = current_id()
    if not id then
      return
    end
    local t = core().get(id)
    close()
    vim.schedule(function()
      core().jump(t)
    end)
  end, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set('n', 'o', function()
    local id = current_id()
    if id then
      require('threads.ui.show').open(core().get(id))
    end
  end, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set('n', 'd', function()
    local id = current_id()
    if not id then
      return
    end
    core().delete(core().get(id))
    close()
    vim.schedule(function()
      M.open(opts)
    end)
  end, { buffer = buf, nowait = true, silent = true })

  return win
end

return M
