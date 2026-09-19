-- threads.nvim: floating or split view of a full conversation
local config = require('threads.config')
local util = require('threads.util')

local M = {}

local function format_ts(ts)
  if not ts or ts == 0 then
    return '?'
  end
  return os.date('%Y-%m-%d %H:%M', ts)
end

--- Build the Show buffer lines. Also returns the 1-based line numbers of the
--- message headers (used by [[ / ]] navigation).
function M.lines_for(t)
  local out = {}
  local message_lines = {}
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
    message_lines[#message_lines + 1] = #out + 1
    add(('── %s (%s) ──'):format(m.role == 'user' and 'you' or (t.agent or 'agent'), format_ts(m.ts)))
    local wrapped = util.wrap(m.content or '', 100)
    if #wrapped == 0 then
      wrapped = { '' }
    end
    for _, line in ipairs(wrapped) do
      add(line)
    end
  end
  return out, message_lines
end

local function make_buffer(t)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  local lines, message_lines = M.lines_for(t)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'markdown'
  return buf, message_lines
end

local function apply_conceal(win, cfg)
  if cfg.conceal ~= false then
    vim.wo[win].conceallevel = 2
    vim.wo[win].concealcursor = 'nc'
  end
end

local function map_keys(buf, win, message_lines, close)
  vim.keymap.set('n', 'q', close, { buffer = buf, nowait = true, silent = true, desc = 'Close thread' })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf, nowait = true, silent = true, desc = 'Close thread' })

  local function goto_message(dir)
    if #message_lines == 0 then
      return
    end
    local cur = vim.api.nvim_win_get_cursor(win)[1]
    local target
    if dir > 0 then
      for _, l in ipairs(message_lines) do
        if l > cur then
          target = l
          break
        end
      end
      target = target or message_lines[1]
    else
      for i = #message_lines, 1, -1 do
        if message_lines[i] < cur then
          target = message_lines[i]
          break
        end
      end
      target = target or message_lines[#message_lines]
    end
    vim.api.nvim_win_set_cursor(win, { target, 0 })
    pcall(vim.cmd, 'normal! zz')
  end

  vim.keymap.set('n', ']]', function()
    goto_message(1)
  end, { buffer = buf, nowait = true, silent = true, desc = 'Next message' })
  vim.keymap.set('n', '[[', function()
    goto_message(-1)
  end, { buffer = buf, nowait = true, silent = true, desc = 'Previous message' })
end

local function open_float(buf, t, cfg, message_lines)
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
    footer = ' [[ / ]] messages · q close ',
    footer_pos = 'center',
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winhighlight = 'NormalFloat:Normal,FloatBorder:ThreadsBorder,FloatTitle:ThreadsTitle,FloatFooter:ThreadsMuted'
  apply_conceal(win, cfg)
  map_keys(buf, win, message_lines, function()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end)
  return win
end

local function open_split(buf, t, cfg, message_lines)
  local size = math.max(math.min(cfg.split_size or 0.4, 0.95), 0.1)
  local dir = cfg.split or 'below'
  if dir == 'left' or dir == 'right' then
    local width = math.max(math.floor(vim.o.columns * size), 20)
    local cmd = (dir == 'left' and 'topleft ' or 'belowright ') .. width .. 'vsplit'
    vim.cmd(cmd)
  else
    local height = math.max(math.floor(vim.o.lines * size), 5)
    local cmd = (dir == 'above' and 'aboveleft ' or 'belowright ') .. height .. 'split'
    vim.cmd(cmd)
  end
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].winfixheight = (dir ~= 'left' and dir ~= 'right')
  vim.wo[win].winhighlight = 'Normal:Normal,WinBar:ThreadsTitle'
  vim.wo[win].winbar = ' thread ' .. t.id:sub(1, 8) .. ' — [[/]] messages · q close '
  apply_conceal(win, cfg)
  map_keys(buf, win, message_lines, function()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end)
  return win
end

--- Open a thread. opts.window = "float" | "split" (defaults to config.show.window).
function M.open(t, opts)
  if not t then
    return
  end
  opts = opts or {}
  local cfg = config.get().show or {}
  local window = opts.window or cfg.window or 'float'
  local buf, message_lines = make_buffer(t)
  if window == 'split' then
    return open_split(buf, t, cfg, message_lines)
  end
  return open_float(buf, t, cfg, message_lines)
end

return M
