-- threads.nvim: read-only floating view of a full conversation
local config = require('threads.config')
local util = require('threads.util')

local M = {}

local function format_ts(ts)
  if not ts or ts == 0 then
    return '?'
  end
  return os.date('%Y-%m-%d %H:%M', ts)
end

function M.lines_for(t)
  local out = {}
  local function add(s)
    out[#out + 1] = s
  end
  add('threads.nvim — thread ' .. t.id)
  add('')
  add('state:   ' .. t.state .. (t.action == 'apply' and ' (apply)' or ''))
  add('file:    ' .. t.file)
  add('lines:   ' .. ((t.range and t.range.start_row or 0) + 1) .. '-' .. ((t.range and t.range.end_row or 0) + 1))
  add('agent:   ' .. (t.agent or '-'))
  add('created: ' .. format_ts(t.created_at))
  add('updated: ' .. format_ts(t.updated_at))
  if t.closed_reason then
    add('closed:  ' .. t.closed_reason)
  end
  if t.error and t.error ~= '' then
    add('error:   ' .. t.error:gsub('\n', ' '))
  end
  add('')
  add('── source ─────────────────────────────')
  for _, line in ipairs(t.snapshot or {}) do
    add(line)
  end
  for _, m in ipairs(t.messages or {}) do
    add('')
    add(('── %s (%s) ──'):format(m.role == 'user' and 'you' or (t.agent or 'agent'), format_ts(m.ts)))
    local wrapped = util.wrap(m.content or '', 100)
    if #wrapped == 0 then
      wrapped = { '' }
    end
    for _, line in ipairs(wrapped) do
      add(line)
    end
  end
  return out
end

function M.open(t)
  if not t then
    return
  end
  local cfg = config.get().show or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'threads-show'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.lines_for(t))
  vim.bo[buf].modifiable = false

  local width = math.max(math.floor(vim.o.columns * (cfg.width or 0.8)), 30)
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
    title = ' thread ' .. t.id:sub(1, 8) .. ' ',
    title_pos = 'center',
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winhighlight = 'NormalFloat:Normal,FloatBorder:ThreadsBorder,FloatTitle:ThreadsTitle'

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  vim.keymap.set('n', 'q', close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf, nowait = true, silent = true })
  return win
end

return M
