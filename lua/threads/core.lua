-- threads.nvim: core state, lifecycle and commands implementation
local config = require('threads.config')
local util = require('threads.util')
local store = require('threads.store')
local agent = require('threads.agent')
local events = require('threads.events')
local ui_input = require('threads.ui.input')
local ui_show = require('threads.ui.show')
local ui_history = require('threads.ui.history')

local M = {}

local track_ns = vim.api.nvim_create_namespace('threads.nvim.track')
local display_ns = vim.api.nvim_create_namespace('threads.nvim.display')
local sign_ns = vim.api.nvim_create_namespace('threads.nvim.sign')

local state = {
  threads = {}, -- id -> thread (runtime fields start with `_`)
  buffers = {}, -- bufnr -> { path, ids, loaded, attached, visible, unloaded }
  running = {}, -- id -> agent handle
  global_visible = true,
  spinner = { frame = 0, timer = nil },
  setup = false,
}

M.state = state
M.track_ns = track_ns
M.display_ns = display_ns
M.sign_ns = sign_ns

local function valid_buf(bufnr)
  return bufnr ~= nil
    and vim.api.nvim_buf_is_valid(bufnr)
    and vim.api.nvim_buf_is_loaded(bufnr)
end

local function render()
  return require('threads.render')
end

--------------------------------------------------------------------------
-- setup
--------------------------------------------------------------------------

function M.apply_keymaps()
  local maps = config.get().keymaps
  if type(maps) ~= 'table' then
    return
  end
  local defs = {
    new = { 'n', function() M.create() end, 'create thread' },
    new_visual = { 'v', nil, 'create thread' },
    send = { 'n', function() M.send() end, 'send thread' },
    send_all = { 'n', function() M.send_all() end, 'send all pending threads' },
    reply = { 'n', function() M.reply() end, 'reply to thread' },
    apply = { 'n', function() M.apply() end, 'apply thread changes' },
    cancel = { 'n', function() M.cancel() end, 'cancel thread request' },
    close = { 'n', function() M.close() end, 'close thread' },
    toggle = { 'n', function() M.toggle() end, 'toggle thread display' },
    next = { 'n', function() M.next() end, 'next thread' },
    prev = { 'n', function() M.prev() end, 'previous thread' },
    delete = { 'n', function() M.delete() end, 'delete thread' },
    show = { 'n', function() M.show() end, 'show thread' },
    peek = { 'n', function() M.peek() end, 'peek thread' },
    history = { 'n', function() M.history() end, 'threads history' },
  }
  for name, lhs in pairs(maps) do
    local def = defs[name]
    if def and type(lhs) == 'string' then
      local rhs = def[2]
      if name == 'new_visual' then
        rhs = ':lua require("threads").create()<CR>'
      end
      vim.keymap.set(def[1], lhs, rhs, {
        silent = true,
        desc = 'threads.nvim: ' .. def[3],
      })
    end
  end
end

function M.setup()
  require('threads.commands').register()
  if state.setup then
    return
  end
  state.setup = true
  render().define_highlights()

  local group = vim.api.nvim_create_augroup('ThreadsNvim', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'BufReadPost', 'BufNewFile' }, {
    group = group,
    callback = function(args)
      local ok, err = pcall(M.ensure, args.buf)
      if not ok then
        util.notify('could not load threads: ' .. tostring(err), vim.log.levels.ERROR)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
    group = group,
    callback = function(args)
      pcall(M.unload, args.buf)
    end,
  })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = function()
      render().define_highlights()
    end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      pcall(M.save_all)
    end,
  })

  M.apply_keymaps()
end

--------------------------------------------------------------------------
-- buffer lifecycle
--------------------------------------------------------------------------

function M.ensure(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if not valid_buf(bufnr) then
    return nil
  end
  local path = util.buf_path(bufnr)
  if not path then
    return nil
  end
  local b = state.buffers[bufnr]
  if b and b.loaded and b.path == path then
    return b
  end
  if b and b.path ~= path then
    M.unload(bufnr)
  end

  b = {
    path = path,
    ids = {},
    loaded = false,
    attached = false,
    visible = state.global_visible,
  }
  state.buffers[bufnr] = b

  local data = store.load(path)
  for _, raw in ipairs(data and data.threads or {}) do
    M._register(bufnr, raw)
  end
  b.loaded = true
  M._attach(bufnr)

  vim.schedule(function()
    if not valid_buf(bufnr) then
      return
    end
    M._reanchor_buffer(bufnr)
    M._validate_buffer(bufnr)
    render().buffer(bufnr)
    M._update_spinner()
  end)
  return b
end

function M.unload(bufnr)
  local b = state.buffers[bufnr]
  if not b then
    return
  end
  local running = false
  for _, id in ipairs(b.ids) do
    if state.running[id] then
      running = true
      break
    end
  end
  if running then
    -- Keep the bookkeeping around until the jobs finish so results persist.
    b.unloaded = true
    return
  end
  if b.loaded and valid_buf(bufnr) then
    pcall(M.save_buffer, bufnr)
  end
  for _, id in ipairs(b.ids) do
    state.threads[id] = nil
  end
  state.buffers[bufnr] = nil
end

function M._register(bufnr, raw)
  if type(raw) ~= 'table' or type(raw.id) ~= 'string' then
    return nil
  end
  raw._bufnr = bufnr
  raw.messages = raw.messages or {}
  raw.snapshot = raw.snapshot or {}
  raw.range = raw.range or { start_row = 0, start_col = 0, end_row = 0, end_col = 0 }
  raw.action = raw.action or 'ask'
  raw.state = raw.state or 'pending'
  raw.created_at = raw.created_at or os.time()
  raw.updated_at = raw.updated_at or raw.created_at
  state.threads[raw.id] = raw
  local b = state.buffers[bufnr]
  if b and not util.list_contains(b.ids, raw.id) then
    b.ids[#b.ids + 1] = raw.id
  end
  return raw
end

function M._attach(bufnr)
  local b = state.buffers[bufnr]
  if not b or b.attached or not valid_buf(bufnr) then
    return
  end
  b.attached = true
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      vim.schedule(function()
        if valid_buf(bufnr) then
          M._validate_buffer(bufnr)
        end
      end)
    end,
    on_reload = function()
      vim.schedule(function()
        if valid_buf(bufnr) then
          M._reanchor_buffer(bufnr)
          M._validate_buffer(bufnr)
          render().buffer(bufnr)
        end
      end)
    end,
    on_detach = function()
      local bs = state.buffers[bufnr]
      if bs then
        bs.attached = false
      end
    end,
  })
end

function M._reanchor_buffer(bufnr)
  local b = state.buffers[bufnr]
  if not b then
    return
  end
  local window = config.get().reanchor_lines or 200
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, id in ipairs(b.ids) do
    local t = state.threads[id]
    if t and t.state ~= 'closed' then
      local r = util.clamp_range(bufnr, t.range)
      if util.same_lines(util.text_in_range(bufnr, r), t.snapshot) then
        t.range = r
      else
        local found = M._search_snapshot(bufnr, t, window, line_count)
        if found then
          t.range = found
        end
      end
    end
  end
end

function M._search_snapshot(bufnr, t, window, line_count)
  local n = #t.snapshot
  if n == 0 then
    return nil
  end
  local original = t.range.start_row
  local function try(start_row)
    if start_row < 0 or start_row + n > line_count then
      return nil
    end
    local candidate = {
      start_row = start_row,
      start_col = t.range.start_col,
      end_row = start_row + n - 1,
      end_col = t.range.end_col,
    }
    if util.same_lines(util.text_in_range(bufnr, candidate), t.snapshot) then
      return util.clamp_range(bufnr, candidate)
    end
    return nil
  end
  for delta = 0, window do
    if delta == 0 then
      local found = try(original)
      if found then
        return found
      end
    else
      local up = try(original - delta)
      if up then
        return up
      end
      local down = try(original + delta)
      if down then
        return down
      end
    end
  end
  return nil
end

function M._tracked_range(bufnr, t)
  if t._track_id then
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, track_ns, t._track_id, { details = true })
    if pos and pos[1] then
      local details = pos[3] or {}
      local range = {
        start_row = pos[1],
        start_col = pos[2],
        end_row = details.end_row or pos[1],
        end_col = details.end_col or pos[2],
      }
      return util.clamp_range(bufnr, range)
    end
    t._track_id = nil
  end
  return util.clamp_range(bufnr, t.range)
end

function M._sync_track(t)
  local bufnr = t._bufnr
  if not valid_buf(bufnr) then
    return
  end
  local r = util.clamp_range(bufnr, t.range)
  if t._track_id then
    local ok = pcall(vim.api.nvim_buf_set_extmark, bufnr, track_ns, r.start_row, r.start_col, {
      id = t._track_id,
      end_row = r.end_row,
      end_col = r.end_col,
      right_gravity = true,
      end_right_gravity = true,
    })
    if ok then
      return
    end
    t._track_id = nil
  end
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, track_ns, r.start_row, r.start_col, {
    end_row = r.end_row,
    end_col = r.end_col,
    right_gravity = true,
    end_right_gravity = true,
  })
  if ok then
    t._track_id = id
  end
end

function M._validate_buffer(bufnr)
  local b = state.buffers[bufnr]
  if not b or not valid_buf(bufnr) then
    return
  end
  local dirty = false
  local changed = false
  for _, id in ipairs(b.ids) do
    local t = state.threads[id]
    if t and t.state ~= 'closed' then
      local range = M._tracked_range(bufnr, t)
      local text = range and util.text_in_range(bufnr, range)
      if range and util.same_lines(text, t.snapshot) then
        if not util.same_range(range, t.range) then
          t.range = range
          dirty = true
        end
        M._sync_track(t)
      else
        M.close(t, 'the source changed')
        changed = true
      end
    end
  end
  if dirty then
    M.save_buffer(bufnr)
  end
  if changed then
    render().buffer(bufnr)
  end
end

--------------------------------------------------------------------------
-- persistence
--------------------------------------------------------------------------

function M.serialize(t)
  local out = {}
  for k, v in pairs(t) do
    if type(k) == 'string' and k:sub(1, 1) ~= '_' and k ~= 'bufnr' then
      out[k] = v
    end
  end
  return out
end

function M.save_buffer(bufnr)
  local b = state.buffers[bufnr]
  if not b then
    return
  end
  local list = {}
  for _, id in ipairs(b.ids) do
    local t = state.threads[id]
    if t then
      list[#list + 1] = M.serialize(t)
    end
  end
  table.sort(list, function(x, y)
    return (x.created_at or 0) < (y.created_at or 0)
  end)
  store.save(b.path, { version = 1, path = b.path, threads = list })
end

function M.save_all()
  for bufnr, b in pairs(state.buffers) do
    if b.loaded and valid_buf(bufnr) then
      M.save_buffer(bufnr)
    end
  end
end

--------------------------------------------------------------------------
-- range helpers
--------------------------------------------------------------------------

local function current_visual_mode()
  local mode = vim.fn.mode()
  if mode == 'v' or mode == 'V' or mode == '\22' then
    return mode
  end
  return nil
end

--- Range from the '< and '> marks (0-indexed, end-col exclusive). Used when a
--- visual mapping cleared the command range with <C-u>.
local function marks_range(bufnr)
  local a = vim.api.nvim_buf_get_mark(bufnr, '<')
  local b = vim.api.nvim_buf_get_mark(bufnr, '>')
  if a[1] <= 0 or b[1] <= 0 then
    return nil
  end
  if vim.fn.visualmode() == 'v' then
    local start, endm = a, b
    if a[1] > b[1] or (a[1] == b[1] and a[2] > b[2]) then
      start, endm = b, a
    end
    return {
      start_row = start[1] - 1,
      start_col = start[2],
      end_row = endm[1] - 1,
      end_col = endm[2] + 1,
    }
  end
  local r1 = math.min(a[1], b[1])
  local r2 = math.max(a[1], b[1])
  return { start_row = r1 - 1, start_col = 0, end_row = r2 - 1 }
end

function M.resolve_range(bufnr, opts)
  opts = opts or {}
  if type(opts.range) == 'table' then
    return util.clamp_range(bufnr, opts.range)
  end

  -- Called from a Lua visual-mode mapping while the selection is still active.
  local vmode = current_visual_mode()
  if vmode then
    local a = vim.fn.getpos('v')
    local b = vim.fn.getpos('.')
    if a[2] > 0 and b[2] > 0 then
      if vmode == 'v' then
        local start, endm = a, b
        if a[2] > b[2] or (a[2] == b[2] and a[3] > b[3]) then
          start, endm = b, a
        end
        return util.clamp_range(bufnr, {
          start_row = start[2] - 1,
          start_col = start[3] - 1,
          end_row = endm[2] - 1,
          end_col = endm[3],
        })
      end
      local r1 = math.min(a[2], b[2])
      local r2 = math.max(a[2], b[2])
      return util.clamp_range(bufnr, { start_row = r1 - 1, start_col = 0, end_row = r2 - 1 })
    end
  end

  local cursor_line = 1
  if vim.api.nvim_get_current_buf() == bufnr then
    cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  end

  -- Explicit command range (':ThreadNew' or ":'<,'>ThreadNew").
  if opts.had_range ~= nil then
    local line1, line2
    if opts.had_range then
      line1 = opts.line1 or cursor_line
      line2 = opts.line2 or line1
    else
      line1, line2 = cursor_line, cursor_line
    end
    line1, line2 = math.min(line1, line2), math.max(line1, line2)
    local start_col, end_col = 0, nil
    if opts.had_range then
      local a = vim.api.nvim_buf_get_mark(bufnr, '<')
      local b = vim.api.nvim_buf_get_mark(bufnr, '>')
      if a[1] == line1 and b[1] == line2 and a[1] > 0 and vim.fn.visualmode() == 'v' then
        start_col = a[2]
        end_col = b[2] + 1
      end
    end
    return util.clamp_range(bufnr, {
      start_row = line1 - 1,
      start_col = start_col,
      end_row = line2 - 1,
      end_col = end_col,
    })
  end

  -- Lua mapping that cleared the range with <C-u>: fall back to visual marks.
  local mr = marks_range(bufnr)
  if mr then
    return util.clamp_range(bufnr, mr)
  end

  -- Last resort: the current line.
  return util.clamp_range(bufnr, {
    start_row = cursor_line - 1,
    start_col = 0,
    end_row = cursor_line - 1,
  })
end

--------------------------------------------------------------------------
-- create / reply
--------------------------------------------------------------------------

function M.create(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  if not M.ensure(bufnr) then
    util.notify('not a file buffer', vim.log.levels.WARN)
    return nil
  end
  local range = M.resolve_range(bufnr, opts)
  local snapshot = util.text_in_range(bufnr, range)
  if #snapshot == 0 or (#snapshot == 1 and snapshot[1] == '') then
    util.notify('nothing selected', vim.log.levels.WARN)
    return nil
  end

  local function do_create(text)
    text = (text or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if text == '' then
      util.notify('empty comment, thread not created', vim.log.levels.WARN)
      return nil
    end
    local now = os.time()
    local t = {
      id = util.id(),
      state = 'pending',
      action = 'ask',
      file = state.buffers[bufnr].path,
      ft = vim.bo[bufnr].filetype,
      range = range,
      snapshot = snapshot,
      messages = { { role = 'user', content = text, ts = now } },
      created_at = now,
      updated_at = now,
      _bufnr = bufnr,
    }
    M._register(bufnr, t)
    M._sync_track(t)
    M._enforce_limit(bufnr)
    M.save_buffer(bufnr)
    render().buffer(bufnr)
    events.emit('created', M.view(t))
    if opts.bang or opts.send then
      M.send(t)
    end
    return t
  end

  if opts.text ~= nil then
    return do_create(opts.text)
  end
  ui_input.prompt({
    title = 'New thread',
    footer = ' <C-s>/<Esc> submit · q cancel ',
    on_submit = do_create,
  })
  return nil
end

--- Append a user message to a thread without sending it.
function M.comment(t, opts)
  opts = opts or {}
  if type(t) == 'string' then
    t = M.get(t)
  end
  t = t or M.current()
  if not t then
    util.notify('no thread here', vim.log.levels.WARN)
    return nil
  end
  t = state.threads[t.id] or t

  local function add(text)
    text = (text or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if text == '' then
      return nil
    end
    t.messages[#t.messages + 1] = { role = 'user', content = text, ts = os.time() }
    t.updated_at = os.time()
    if t.state ~= 'sent' then
      t.state = 'pending'
      t.closed_reason = nil
    end
    M.save_buffer(t._bufnr)
    render().thread(t)
    events.emit('commented', M.view(t))
    return t
  end

  if opts.text ~= nil then
    return add(opts.text)
  end
  ui_input.prompt({
    title = 'Comment on ' .. t.id:sub(1, 8),
    footer = ' <C-s>/<Esc> add · q cancel ',
    on_submit = add,
  })
  return nil
end

function M.reply(t, opts)
  opts = opts or {}
  if type(t) == 'string' then
    t = M.get(t)
  end
  t = t or M.current()
  if not t then
    util.notify('no thread here', vim.log.levels.WARN)
    return nil
  end
  t = state.threads[t.id] or t

  local function add_and_send(text)
    text = (text or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if text == '' then
      return nil
    end
    t.messages[#t.messages + 1] = { role = 'user', content = text, ts = os.time() }
    t.updated_at = os.time()
    if t.state == 'closed' then
      t.state = 'pending'
      t.closed_reason = nil
    end
    M.save_buffer(t._bufnr)
    render().thread(t)
    return M.send(t, { action = opts.action })
  end

  if opts.text ~= nil then
    return add_and_send(opts.text)
  end
  ui_input.prompt({
    title = 'Reply to ' .. t.id:sub(1, 8),
    footer = ' <C-s>/<Esc> send · q cancel ',
    on_submit = add_and_send,
  })
  return nil
end

--------------------------------------------------------------------------
-- sending
--------------------------------------------------------------------------

function M.send(t, opts)
  opts = opts or {}
  if type(t) == 'string' then
    t = M.get(t)
  end
  t = t or M.current()
  if not t then
    util.notify('no thread here', vim.log.levels.WARN)
    return nil
  end
  t = state.threads[t.id]
  if not t then
    util.notify('thread is not loaded (open the file first)', vim.log.levels.WARN)
    return nil
  end
  local bufnr = t._bufnr
  if not valid_buf(bufnr) then
    util.notify('thread buffer is gone', vim.log.levels.WARN)
    return nil
  end
  if state.running[t.id] then
    util.notify('thread is already waiting for a response', vim.log.levels.WARN)
    return nil
  end
  if t.state == 'closed' then
    util.notify('thread is closed', vim.log.levels.WARN)
    return nil
  end
  local has_user = false
  for _, m in ipairs(t.messages) do
    if m.role == 'user' then
      has_user = true
      break
    end
  end
  if not has_user then
    util.notify('thread has no user message', vim.log.levels.WARN)
    return nil
  end

  if opts.action then
    t.action = opts.action
  end
  local whole_file = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
  local spec = agent.resolve()
  t.agent = spec and spec.name or nil
  t.state = 'sent'
  t.error = nil
  t.updated_at = os.time()
  M.save_buffer(bufnr)
  render().thread(t)
  M._update_spinner()
  events.emit('sent', M.view(t))

  local handle, err = agent.run(t, {
    whole_file = whole_file,
    on_exit = function(result)
      vim.schedule(function()
        M._on_agent_exit(t, result)
      end)
    end,
  })
  if not handle then
    t.state = 'error'
    t.error = err or 'could not start agent'
    t.updated_at = os.time()
    M.save_buffer(bufnr)
    render().thread(t)
    M._update_spinner()
    util.notify(t.error, vim.log.levels.ERROR)
    events.emit('error', M.view(t))
    return nil
  end
  state.running[t.id] = handle
  M._update_spinner()
  return t
end

function M._on_agent_exit(t, result)
  state.running[t.id] = nil
  if not t or not state.threads[t.id] then
    M._update_spinner()
    return
  end
  local bufnr = t._bufnr
  if t.state == 'closed' then
    M.save_buffer(bufnr)
    render().thread(t)
    M._update_spinner()
    return
  end
  if t._canceled then
    t._canceled = nil
    M.save_buffer(bufnr)
    render().thread(t)
    M._update_spinner()
    return
  end

  local out = (result.stdout or ''):gsub('%s+$', '')
  local err = (result.stderr or ''):gsub('%s+$', '')
  if result.timed_out then
    t.state = 'error'
    t.error = 'agent timed out'
  elseif result.code ~= 0 then
    t.state = 'error'
    t.error = err ~= '' and err or ('agent exited with code ' .. tostring(result.code))
  else
    t.state = 'answered'
    t.error = nil
    t.messages[#t.messages + 1] = {
      role = 'assistant',
      content = out ~= '' and out or '(no output)',
      ts = os.time(),
      agent = t.agent,
    }
  end
  t.updated_at = os.time()
  M.save_buffer(bufnr)
  render().thread(t)
  M._update_spinner()

  if t.action == 'apply' and result.code == 0 and not result.timed_out then
    M._reload_file(t)
  end

  if t.state == 'answered' then
    if t.action == 'apply' then
      util.notify('thread ' .. t.id:sub(1, 8) .. ' applied changes')
    else
      util.notify('thread ' .. t.id:sub(1, 8) .. ' answered')
    end
  else
    util.notify('thread ' .. t.id:sub(1, 8) .. ' failed: ' .. (t.error or ''), vim.log.levels.ERROR)
  end
  events.emit(t.state == 'answered' and 'answered' or 'error', M.view(t))

  local b = state.buffers[bufnr]
  if b and b.unloaded then
    M.unload(bufnr)
  end
end

function M._reload_file(t)
  vim.schedule(function()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if valid_buf(bufnr) then
        local path = util.buf_path(bufnr)
        if path == t.file then
          if vim.bo[bufnr].modified then
            util.notify(
              'the agent edited ' .. util.file_label(t.file)
                .. ' on disk, but the buffer has unsaved changes. Use :edit! to reload.',
              vim.log.levels.WARN
            )
          else
            vim.api.nvim_buf_call(bufnr, function()
              vim.cmd('silent! checktime')
            end)
          end
        end
      end
    end
  end)
end

function M.send_all(opts)
  opts = opts or {}
  local bufnrs
  if opts.all then
    bufnrs = vim.tbl_keys(state.buffers)
  else
    bufnrs = { opts.bufnr or vim.api.nvim_get_current_buf() }
  end

  local targets = {}
  for _, bufnr in ipairs(bufnrs) do
    if valid_buf(bufnr) then
      M.ensure(bufnr)
      local b = state.buffers[bufnr]
      for _, id in ipairs(b and b.ids or {}) do
        local t = state.threads[id]
        if t and t.state == 'pending' and not state.running[t.id] then
          targets[#targets + 1] = t
        end
      end
    end
  end

  if #targets == 0 then
    util.notify('no pending threads')
    return 0
  end
  for _, t in ipairs(targets) do
    M.send(t, { action = opts.action })
  end
  util.notify(('sending %d thread(s)'):format(#targets))
  return #targets
end

function M.apply(t, opts)
  return M.send(t, vim.tbl_extend('force', opts or {}, { action = 'apply' }))
end

function M.apply_all(opts)
  return M.send_all(vim.tbl_extend('force', opts or {}, { action = 'apply' }))
end

function M.cancel(t)
  if type(t) == 'string' then
    t = M.get(t)
  end
  t = t or M.current()
  if not t then
    util.notify('no thread here', vim.log.levels.WARN)
    return
  end
  local handle = state.running[t.id]
  if not handle then
    util.notify('thread is not waiting for a response', vim.log.levels.WARN)
    return
  end
  t._canceled = true
  handle.stop()
  state.running[t.id] = nil
  if t.state == 'sent' then
    t.state = 'pending'
  end
  t.updated_at = os.time()
  M.save_buffer(t._bufnr)
  render().thread(t)
  M._update_spinner()
  events.emit('canceled', M.view(t))
  util.notify('thread ' .. t.id:sub(1, 8) .. ' canceled')
end

function M.close(t, reason)
  if type(t) == 'string' then
    t = M.get(t)
  end
  t = t or M.current()
  if not t then
    util.notify('no thread here', vim.log.levels.WARN)
    return
  end
  if t.state == 'closed' then
    return
  end
  t.state = 'closed'
  t.closed_reason = reason or 'closed by user'
  t.updated_at = os.time()
  M.save_buffer(t._bufnr)
  render().thread(t)
  M._update_spinner()
  events.emit('closed', M.view(t))
end

--------------------------------------------------------------------------
-- selection / lookup
--------------------------------------------------------------------------

function M.current(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  M.ensure(bufnr)
  local b = state.buffers[bufnr]
  if not b then
    return nil
  end
  local row
  if vim.api.nvim_get_current_buf() == bufnr then
    row = vim.api.nvim_win_get_cursor(0)[1] - 1
  else
    row = vim.api.nvim_buf_line_count(bufnr) - 1
  end
  local best
  for _, id in ipairs(b.ids) do
    local t = state.threads[id]
    if t and not (t.state == 'closed' and opts.include_closed ~= true) then
      if row >= t.range.start_row and row <= t.range.end_row then
        if not best or t.range.start_row > best.range.start_row then
          best = t
        end
      end
    end
  end
  if best then
    return best
  end
  for _, id in ipairs(b.ids) do
    local t = state.threads[id]
    if t and not (t.state == 'closed' and opts.include_closed ~= true) and t.range.end_row <= row then
      if not best or t.range.end_row > best.range.end_row then
        best = t
      end
    end
  end
  return best
end

function M.get(id)
  if not id or id == '' then
    return nil
  end
  if state.threads[id] then
    return state.threads[id]
  end
  local matches = {}
  for tid, t in pairs(state.threads) do
    if tid:sub(1, #id) == id then
      matches[#matches + 1] = t
    end
  end
  if #matches == 1 then
    return matches[1]
  end
  if #matches > 1 then
    return nil
  end
  for _, data in ipairs(store.load_all()) do
    for _, raw in ipairs(data.threads or {}) do
      if type(raw.id) == 'string' and (raw.id == id or raw.id:sub(1, #id) == id) then
        raw.file = raw.file or data.path
        return raw
      end
    end
  end
  return nil
end

function M.view(t)
  local last = t.messages and t.messages[#t.messages]
  return {
    id = t.id,
    state = t.state,
    action = t.action,
    file = t.file,
    ft = t.ft,
    bufnr = t._bufnr,
    range = util.deepcopy(t.range) or { start_row = 0, start_col = 0, end_row = 0, end_col = 0 },
    snapshot = util.deepcopy(t.snapshot),
    messages = t.messages,
    created_at = t.created_at,
    updated_at = t.updated_at,
    closed_reason = t.closed_reason,
    error = t.error,
    agent = t.agent,
    n_messages = #(t.messages or {}),
    preview = util.preview(last and last.content or '', 80),
  }
end

function M.list(opts)
  opts = opts or {}
  local out = {}
  local seen = {}

  local function push(t)
    if seen[t.id] then
      return
    end
    seen[t.id] = true
    out[#out + 1] = M.view(t)
  end

  if opts.all then
    for _, t in pairs(state.threads) do
      if opts.include_closed ~= false or t.state ~= 'closed' then
        push(t)
      end
    end
    for _, data in ipairs(store.load_all()) do
      for _, raw in ipairs(data.threads or {}) do
        if not seen[raw.id] then
          if opts.include_closed ~= false or raw.state ~= 'closed' then
            raw.file = raw.file or data.path
            seen[raw.id] = true
            out[#out + 1] = M.view(raw)
          end
        end
      end
    end
  else
    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    M.ensure(bufnr)
    local b = state.buffers[bufnr]
    for _, id in ipairs(b and b.ids or {}) do
      local t = state.threads[id]
      if t and (opts.include_closed ~= false or t.state ~= 'closed') then
        push(t)
      end
    end
  end

  table.sort(out, function(a, b)
    if opts.sort == 'updated' then
      return (a.updated_at or 0) > (b.updated_at or 0)
    end
    if a.file ~= b.file then
      return (a.file or '') < (b.file or '')
    end
    if a.range.start_row ~= b.range.start_row then
      return a.range.start_row < b.range.start_row
    end
    return (a.created_at or 0) < (b.created_at or 0)
  end)
  return out
end

--------------------------------------------------------------------------
-- navigation
--------------------------------------------------------------------------

function M.jump(t)
  if not t then
    return
  end
  t = state.threads[t.id] or t
  local bufnr = t._bufnr
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    if vim.fn.filereadable(t.file) ~= 1 then
      util.notify('file not found: ' .. tostring(t.file), vim.log.levels.WARN)
      return
    end
    vim.cmd.edit(vim.fn.fnameescape(t.file))
    bufnr = vim.api.nvim_get_current_buf()
    M.ensure(bufnr)
    t = state.threads[t.id] or t
  end

  if not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.cmd.buffer(bufnr)
  end
  local win
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == bufnr then
      win = w
      break
    end
  end
  if win then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd.buffer(bufnr)
  end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local row = math.min((t.range and t.range.start_row or 0) + 1, line_count)
  local col = (t.range and t.range.start_col) or 0
  pcall(vim.api.nvim_win_set_cursor, 0, { row, col })
  pcall(vim.cmd, 'normal! zz')
  events.emit('jumped', M.view(t))
  return bufnr
end

local function navigable(bufnr)
  M.ensure(bufnr)
  local b = state.buffers[bufnr]
  if not b then
    return {}
  end
  local list = {}
  for _, id in ipairs(b.ids) do
    local t = state.threads[id]
    if t and t.state ~= 'closed' then
      list[#list + 1] = t
    end
  end
  table.sort(list, function(x, y)
    return x.range.start_row < y.range.start_row
  end)
  return list
end

function M.next(opts)
  opts = opts or {}
  local list = navigable(vim.api.nvim_get_current_buf())
  if #list == 0 then
    util.notify('no threads in this buffer')
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local target
  for _, t in ipairs(list) do
    if t.range.start_row > row then
      target = t
      break
    end
  end
  target = target or list[1]
  M.jump(target)
  if opts.show then
    ui_show.open(target)
  end
  return target
end

function M.prev(opts)
  opts = opts or {}
  local list = navigable(vim.api.nvim_get_current_buf())
  if #list == 0 then
    util.notify('no threads in this buffer')
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local target
  for i = #list, 1, -1 do
    if list[i].range.start_row < row then
      target = list[i]
      break
    end
  end
  target = target or list[#list]
  M.jump(target)
  if opts.show then
    ui_show.open(target)
  end
  return target
end

function M.show(t, opts)
  if type(t) == 'string' then
    t = M.get(t)
  end
  t = t or M.current()
  if not t then
    util.notify('no thread here', vim.log.levels.WARN)
    return
  end
  return ui_show.open(t, opts)
end

function M.peek(t, opts)
  if type(t) == 'string' then
    t = M.get(t)
  end
  t = t or M.current()
  if not t then
    util.notify('no thread here', vim.log.levels.WARN)
    return
  end
  return ui_show.peek(t, opts)
end

--- Expand/collapse a thread's inline rendering (shows all message lines).
function M.expand(t, expanded)
  if type(t) == 'string' then
    t = M.get(t)
  end
  t = t or M.current()
  if not t then
    util.notify('no thread here', vim.log.levels.WARN)
    return nil
  end
  t = state.threads[t.id] or t
  if expanded == nil then
    expanded = not t._expanded
  end
  t._expanded = expanded or nil
  render().thread(t)
  events.emit('expanded', M.view(t))
  return t._expanded
end

function M.toggle_expand(t)
  return M.expand(t)
end

function M.history(opts)
  return ui_history.open(opts or {})
end

--------------------------------------------------------------------------
-- delete / toggle
--------------------------------------------------------------------------

function M._remove(t)
  state.threads[t.id] = nil
  state.running[t.id] = nil
  local b = state.buffers[t._bufnr]
  if b then
    for i, id in ipairs(b.ids) do
      if id == t.id then
        table.remove(b.ids, i)
        break
      end
    end
  end
end

function M._enforce_limit(bufnr)
  local limit = config.get().storage.max_threads or 300
  local b = state.buffers[bufnr]
  if not b or #b.ids <= limit then
    return
  end
  local closed = {}
  for _, id in ipairs(b.ids) do
    local t = state.threads[id]
    if t and t.state == 'closed' then
      closed[#closed + 1] = t
    end
  end
  table.sort(closed, function(x, y)
    return (x.updated_at or 0) < (y.updated_at or 0)
  end)
  local excess = #b.ids - limit
  for i = 1, math.min(excess, #closed) do
    M._remove(closed[i])
  end
end

function M.delete(t)
  if type(t) == 'string' then
    t = M.get(t)
  end
  t = t or M.current()
  if not t then
    util.notify('no thread here', vim.log.levels.WARN)
    return
  end
  t = state.threads[t.id] or t
  local handle = state.running[t.id]
  if handle then
    handle.stop()
  end
  local bufnr = t._bufnr
  local id = t.id
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and t._sign_id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, sign_ns, t._sign_id)
  end
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and t._display_id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, display_ns, t._display_id)
  end
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and t._track_id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, track_ns, t._track_id)
  end
  M._remove(t)
  if bufnr then
    M.save_buffer(bufnr)
    render().buffer(bufnr)
  end
  M._update_spinner()
  util.notify('thread ' .. id:sub(1, 8) .. ' deleted')
  events.emit('deleted', { id = id, file = t.file })
end

function M.delete_all(opts)
  opts = opts or {}
  local count = 0

  local function wipe_buffer(bufnr)
    local b = state.buffers[bufnr]
    if not b then
      return
    end
    local ids = util.deepcopy(b.ids)
    for _, id in ipairs(ids) do
      local t = state.threads[id]
      if t then
        local handle = state.running[id]
        if handle then
          handle.stop()
        end
        if t._sign_id and vim.api.nvim_buf_is_valid(bufnr) then
          pcall(vim.api.nvim_buf_del_extmark, bufnr, sign_ns, t._sign_id)
        end
        if t._display_id and vim.api.nvim_buf_is_valid(bufnr) then
          pcall(vim.api.nvim_buf_del_extmark, bufnr, display_ns, t._display_id)
        end
        if t._track_id and vim.api.nvim_buf_is_valid(bufnr) then
          pcall(vim.api.nvim_buf_del_extmark, bufnr, track_ns, t._track_id)
        end
        M._remove(t)
        count = count + 1
      end
    end
    M.save_buffer(bufnr)
    render().buffer(bufnr)
  end

  if opts.all then
    for bufnr in pairs(state.buffers) do
      wipe_buffer(bufnr)
    end
    -- Thread files that were never loaded in this session.
    for _, path in ipairs(store.files()) do
      vim.fn.delete(path)
    end
  else
    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    M.ensure(bufnr)
    if not state.buffers[bufnr] then
      util.notify('not a file buffer', vim.log.levels.WARN)
      return 0
    end
    wipe_buffer(bufnr)
  end

  M._update_spinner()
  util.notify(('deleted %d thread(s)'):format(count))
  events.emit('cleared', { count = count, all = opts.all and true or false })
  return count
end

function M.toggle(all)
  if all then
    state.global_visible = not state.global_visible
    for _, b in pairs(state.buffers) do
      b.visible = state.global_visible
    end
  else
    local bufnr = vim.api.nvim_get_current_buf()
    M.ensure(bufnr)
    local b = state.buffers[bufnr]
    if not b then
      util.notify('not a file buffer', vim.log.levels.WARN)
      return
    end
    b.visible = not b.visible
  end
  render().all()
  events.emit('toggled', { visible = state.global_visible })
end

--------------------------------------------------------------------------
-- status
--------------------------------------------------------------------------

function M.status(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  M.ensure(bufnr)
  local b = state.buffers[bufnr]
  local counts = { pending = 0, sent = 0, answered = 0, closed = 0, error = 0 }
  if b then
    for _, id in ipairs(b.ids) do
      local t = state.threads[id]
      if t then
        counts[t.state] = (counts[t.state] or 0) + 1
      end
    end
  end
  counts.total = 0
  for _, v in pairs(counts) do
    counts.total = counts.total + v
  end
  return counts
end

function M.statusline()
  local c = M.status()
  local parts = {}
  if c.pending > 0 then
    parts[#parts + 1] = '○ ' .. c.pending
  end
  if c.sent > 0 then
    parts[#parts + 1] = '◌ ' .. c.sent
  end
  if c.error > 0 then
    parts[#parts + 1] = '! ' .. c.error
  end
  if #parts == 0 then
    return ''
  end
  return 'threads ' .. table.concat(parts, ' ')
end

--------------------------------------------------------------------------
-- spinner
--------------------------------------------------------------------------

function M._update_spinner()
  local any = false
  for _, t in pairs(state.threads) do
    if t.state == 'sent' and state.running[t.id] then
      any = true
      break
    end
  end
  local spinner = state.spinner
  if any and not spinner.timer then
    spinner.timer = vim.uv.new_timer()
    spinner.timer:start(120, 120, vim.schedule_wrap(function()
      spinner.frame = spinner.frame + 1
      for _, t in pairs(state.threads) do
        if t.state == 'sent' then
          render().thread(t)
        end
      end
    end))
  elseif not any and spinner.timer then
    spinner.timer:stop()
    spinner.timer:close()
    spinner.timer = nil
  end
end

return M
