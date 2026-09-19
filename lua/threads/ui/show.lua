-- threads.nvim: floating or split view of a full conversation
local config = require('threads.config')
local util = require('threads.util')

local M = {}

local active_peek = { win = nil, id = nil }

local GUTTER = '  ▌ '

local function format_ts(ts)
  if not ts or ts == 0 then
    return '?'
  end
  return os.date('%Y-%m-%d %H:%M', ts)
end

local function icon_for(t)
  local icons = config.get().icons
  return icons[t.state] or '?'
end

local function state_hl(t)
  local map = {
    pending = 'ThreadsStatePending',
    sent = 'ThreadsStateSent',
    answered = 'ThreadsStateAnswered',
    closed = 'ThreadsStateClosed',
    error = 'ThreadsStateError',
  }
  return map[t.state] or 'ThreadsStatePending'
end

local function label_for(t)
  local labels = { pending = 'pending', sent = 'waiting', answered = 'answered', closed = 'closed', error = 'error' }
  local label = labels[t.state] or t.state
  label = label .. ' · ' .. (t.action == 'apply' and 'apply' or 'ask')
  return label
end

--- Build the Show buffer as styled lines. Each line is a list of
--- { text, hl_group } chunks (hl may be nil to keep native markdown colors).
--- Also returns the 1-based line numbers of the message headers.
function M.chunks_for(t)
  local out = {}
  local message_lines = {}
  local width = math.max(math.min(vim.o.columns - 12, 100), 30)

  local function card(chunks)
    local line = { { GUTTER, 'ThreadsBorder' } }
    for _, c in ipairs(chunks) do
      line[#line + 1] = c
    end
    out[#out + 1] = line
  end

  local function meta(label, value)
    card({ { string.format('%-8s', label), 'ThreadsMuted' }, { value or '', 'ThreadsMeta' } })
  end

  card({
    { icon_for(t) .. ' ', state_hl(t) },
    { 'thread ', 'ThreadsMuted' },
    { t.id:sub(1, 8), 'ThreadsId' },
    { '  [' .. label_for(t) .. ']', state_hl(t) },
  })
  meta('file', t.file)
  meta('lines', ((t.range and t.range.start_row or 0) + 1) .. '-' .. ((t.range and t.range.end_row or 0) + 1))
  meta('agent', t.agent or '-')
  meta('created', format_ts(t.created_at))
  meta('updated', format_ts(t.updated_at))
  if t.closed_reason then
    meta('closed', t.closed_reason)
  end
  if t.error and t.error ~= '' then
    meta('error', t.error:gsub('\n', ' '))
  end

  card({ { 'source', 'ThreadsMuted' } })
  for _, line in ipairs(t.snapshot or {}) do
    card({ { '  ', 'ThreadsBorder' }, { line, 'ThreadsMdCodeBlock' } })
  end

  for _, m in ipairs(t.messages or {}) do
    out[#out + 1] = { { GUTTER, 'ThreadsBorder' } }
    message_lines[#message_lines + 1] = #out + 1
    local is_user = m.role == 'user'
    local who = is_user and 'you' or (t.agent or 'agent')
    local who_hl = is_user and 'ThreadsLabelUser' or 'ThreadsLabelAssistant'
    card({ { is_user and '▸ ' or '◆ ', who_hl }, { who, who_hl }, { '  ' .. format_ts(m.ts), 'ThreadsMuted' } })
    -- Content stays as raw markdown (2-space indent keeps block syntax valid)
    -- so 'filetype=markdown' + conceal renders it natively.
    for _, raw in ipairs(util.wrap(m.content or '', width)) do
      out[#out + 1] = { { '  ', 'ThreadsBorder' }, { raw, nil } }
    end
  end
  return out, message_lines
end

--- Plain-text version of the Show lines (kept for compatibility/tests).
function M.lines_for(t)
  local chunk_lines, message_lines = M.chunks_for(t)
  local lines = {}
  for i, chunks in ipairs(chunk_lines) do
    local parts = {}
    for _, c in ipairs(chunks) do
      parts[#parts + 1] = c[1]
    end
    lines[i] = table.concat(parts)
  end
  return lines, message_lines
end

local function set_chunked_lines(buf, chunk_lines)
  local texts = {}
  local specs = {}
  for i, chunks in ipairs(chunk_lines) do
    local parts = {}
    local col = 0
    for _, c in ipairs(chunks) do
      local text, hl = c[1], c[2]
      if text ~= '' then
        parts[#parts + 1] = text
        if hl then
          specs[#specs + 1] = { i - 1, col, col + #text, hl }
        end
        col = col + #text
      end
    end
    texts[i] = table.concat(parts)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, texts)
  local ns = vim.api.nvim_create_namespace('threads.nvim.show')
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, s in ipairs(specs) do
    pcall(vim.api.nvim_buf_add_highlight, buf, ns, s[4], s[1], s[2], s[3])
  end
end

local function make_buffer(t)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  local chunk_lines, message_lines = M.chunks_for(t)
  set_chunked_lines(buf, chunk_lines)
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

--- Cursor-relative peek, like vim.diagnostic.open_float. Calling it again for
--- the same thread toggles the window closed.
function M.peek(t, opts)
  if not t then
    return
  end
  if active_peek.win and vim.api.nvim_win_is_valid(active_peek.win) then
    pcall(vim.api.nvim_win_close, active_peek.win, true)
    local same = active_peek.id == t.id
    active_peek.win, active_peek.id = nil, nil
    if same then
      return nil
    end
  end

  opts = opts or {}
  local cfg = opts.config or config.get().peek or {}
  local buf, message_lines = make_buffer(t)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local maxw = 0
  for _, l in ipairs(lines) do
    maxw = math.max(maxw, vim.fn.strdisplaywidth(l))
  end
  local width = math.max(math.min(maxw + 2, cfg.width or 80), 20)
  width = math.min(width, math.max(vim.o.columns - 4, 20))
  local height = math.max(math.min(#lines, cfg.height or 15), 3)
  height = math.min(height, math.max(vim.o.lines - 4, 3))

  local win = vim.api.nvim_open_win(buf, cfg.focus ~= false, {
    relative = opts.relative or 'cursor',
    row = opts.row or 1,
    col = opts.col or 0,
    width = width,
    height = height,
    style = 'minimal',
    border = cfg.border or 'rounded',
    title = ' thread ' .. t.id:sub(1, 8) .. ' ',
    title_pos = 'center',
    focusable = true,
    zindex = 60,
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winhighlight = 'NormalFloat:Normal,FloatBorder:ThreadsBorder,FloatTitle:ThreadsTitle'
  apply_conceal(win, { conceal = config.get().show.conceal })
  map_keys(buf, win, message_lines, function()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end)
  active_peek.win, active_peek.id = win, t.id
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win),
    once = true,
    callback = function()
      if active_peek.win == win then
        active_peek.win, active_peek.id = nil, nil
      end
    end,
  })
  return win
end

return M
