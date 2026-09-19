-- threads.nvim: render threads as virtual lines (never written to the file)
local config = require('threads.config')
local util = require('threads.util')

local M = {}

local SPINNER = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

local function core()
  return require('threads.core')
end

function M.spinner_frame()
  local s = core().state.spinner
  return SPINNER[(s.frame % #SPINNER) + 1]
end

local function icon_for(t)
  local icons = config.get().icons
  if t.state == 'sent' then
    return M.spinner_frame()
  end
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
  local labels = {
    pending = 'pending',
    sent = 'waiting',
    answered = 'answered',
    closed = 'closed',
    error = 'error',
  }
  local label = labels[t.state] or t.state
  if t.action == 'apply' and t.state ~= 'closed' then
    label = label .. '·apply'
  end
  return label
end

local function content_width(bufnr)
  local ok, win = pcall(vim.api.nvim_get_current_win)
  if ok and vim.api.nvim_win_get_buf(win) == bufnr then
    local w = vim.api.nvim_win_get_width(win)
    if w > 20 then
      return w
    end
  end
  return math.max(vim.o.columns, 40)
end

--- Build the virt_lines chunks for a thread.
function M.build(t)
  local cfg = config.get()
  local d = cfg.display
  local pad = d.padding or '  '
  local width = math.max(content_width(t._bufnr) - #pad - 6, 20)
  local lines = {}
  local function add(chunks)
    lines[#lines + 1] = chunks
  end

  add({
    { pad .. '▌ ', 'ThreadsBorder' },
    { icon_for(t) .. ' ', state_hl(t) },
    { 'thread ' .. t.id:sub(1, 8) .. ' ', 'ThreadsId' },
    { '[' .. label_for(t) .. ']', state_hl(t) },
  })

  local max_message_lines = d.max_message_lines or 8
  for _, m in ipairs(t.messages or {}) do
    local is_user = m.role == 'user'
    local who = is_user and 'you' or (t.agent or 'agent')
    local who_hl = is_user and 'ThreadsLabelUser' or 'ThreadsLabelAssistant'
    add({
      { pad .. '  ', 'ThreadsBorder' },
      { is_user and '▸ ' or '◆ ', who_hl },
      { who .. ':', who_hl },
    })
    local content = m.content or ''
    if content == '' then
      content = '(empty)'
    end
    local wrapped = util.wrap(content, width)
    local shown = 0
    for _, line in ipairs(wrapped) do
      if shown >= max_message_lines then
        add({
          { pad .. '    ', 'ThreadsBorder' },
          { ('… %d more line(s) — :ThreadShow'):format(#wrapped - shown), 'ThreadsMuted' },
        })
        break
      end
      add({
        { pad .. '    ', 'ThreadsBorder' },
        { line, 'ThreadsText' },
      })
      shown = shown + 1
    end
  end

  if t.state == 'sent' then
    add({
      { pad .. '  ', 'ThreadsBorder' },
      { icon_for(t) .. ' waiting for ' .. (t.agent or 'agent') .. '…', 'ThreadsStateSent' },
    })
  elseif t.state == 'error' and t.error and t.error ~= '' then
    for _, line in ipairs(util.wrap(t.error, width)) do
      add({ { pad .. '  ', 'ThreadsBorder' }, { line, 'ThreadsStateError' } })
    end
  elseif t.state == 'closed' and t.closed_reason and t.closed_reason ~= '' then
    add({ { pad .. '  ', 'ThreadsBorder' }, { 'closed: ' .. t.closed_reason, 'ThreadsMuted' } })
  end

  local max_lines = d.max_lines or 30
  if #lines > max_lines then
    local trimmed = {}
    for i = 1, max_lines - 1 do
      trimmed[i] = lines[i]
    end
    trimmed[max_lines] = { { pad .. '  … thread truncated — :ThreadShow', 'ThreadsMuted' } }
    lines = trimmed
  end
  return lines
end

--- (Re)draw a single thread.
function M.thread(t)
  if not t or not t._bufnr or not vim.api.nvim_buf_is_valid(t._bufnr) then
    return
  end
  local bufnr = t._bufnr
  local state = core().state
  local ns = core().display_ns
  local b = state.buffers[bufnr]
  local display = config.get().display
  local visible = b and b.visible and display.enabled

  if not visible or (t.state == 'closed' and not display.show_closed) or not vim.api.nvim_buf_is_loaded(bufnr) then
    if t._display_id then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, t._display_id)
      t._display_id = nil
    end
    return
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local row = math.min(math.max(t.range.end_row or 0, 0), math.max(line_count - 1, 0))
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
    id = t._display_id,
    virt_lines = M.build(t),
    virt_lines_leftcol = false,
  })
  if ok then
    t._display_id = id
  else
    t._display_id = nil
  end
end

--- Redraw every thread in a buffer.
function M.buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local b = core().state.buffers[bufnr]
  if not b then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, core().display_ns, 0, -1)
  for _, id in ipairs(b.ids) do
    local t = core().state.threads[id]
    if t then
      t._display_id = nil
    end
  end
  if not b.visible or not config.get().display.enabled then
    return
  end
  for _, id in ipairs(b.ids) do
    local t = core().state.threads[id]
    if t then
      M.thread(t)
    end
  end
end

function M.all()
  for bufnr in pairs(core().state.buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      M.buffer(bufnr)
    end
  end
end

function M.define_highlights()
  local groups = {
    ThreadsBorder = { link = 'Comment' },
    ThreadsId = { link = 'Identifier' },
    ThreadsText = { link = 'Normal' },
    ThreadsMuted = { link = 'Comment' },
    ThreadsLabelUser = { link = 'Title' },
    ThreadsLabelAssistant = { link = 'String' },
    ThreadsStatePending = { link = 'DiagnosticWarn' },
    ThreadsStateSent = { link = 'DiagnosticInfo' },
    ThreadsStateAnswered = { link = 'DiagnosticOk' },
    ThreadsStateClosed = { link = 'Comment' },
    ThreadsStateError = { link = 'DiagnosticError' },
    ThreadsTitle = { link = 'Title' },
  }
  for name, spec in pairs(groups) do
    vim.api.nvim_set_hl(0, name, spec)
  end
end

return M
