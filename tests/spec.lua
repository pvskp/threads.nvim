-- Headless smoke tests for threads.nvim.
-- Run: nvim --headless -u tests/minimal_init.lua -c "luafile tests/spec.lua"

local failures = {}
local passed = 0

local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
    print('PASS  ' .. name)
  else
    failures[#failures + 1] = name .. '\n' .. tostring(err)
    print('FAIL  ' .. name .. '\n' .. tostring(err))
  end
end

local function ok(cond, msg)
  if not cond then
    error(msg or 'expected truthy value', 2)
  end
end

local function eq(a, b, msg)
  if a ~= b then
    error(('%s: expected %s, got %s'):format(msg or 'not equal', vim.inspect(b), vim.inspect(a)), 2)
  end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, 'p')
local datadir = tmp .. '/data'

local threads = require('threads')
local store = require('threads.store')
local core = require('threads.core')

threads.setup({
  storage = { dir = datadir },
  agent = { cmd = { 'cat' }, mode = 'stdin' },
})

local function wait_state(id, state, timeout)
  return vim.wait(timeout or 5000, function()
    local t = threads.get(id)
    return t and t.state == state
  end, 20)
end

local function fresh_buffer(name, lines)
  local path = tmp .. '/' .. name
  vim.fn.writefile(lines, path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  return vim.fn.fnamemodify(path, ':p')
end

--------------------------------------------------------------------------
test('create thread, list it, persist it', function()
  local path = fresh_buffer('basic.lua', { 'local a = 1', 'local b = 2', 'local c = 3' })
  local t = threads.create({
    range = { start_row = 1, start_col = 0, end_row = 1, end_col = 11 },
    text = 'Why is b here?',
  })
  ok(t and t.id, 'thread not created')
  eq(threads.get(t.id).state, 'pending')
  eq(#threads.list(), 1)
  eq(threads.get(t.id).snapshot[1], 'local b = 2')
  local data = store.load(path)
  eq(#data.threads, 1)
  eq(data.threads[1].id, t.id)
  eq(data.threads[1].messages[1].content, 'Why is b here?')
end)

--------------------------------------------------------------------------
test('empty comment is rejected', function()
  fresh_buffer('empty.lua', { 'x' })
  local before = #threads.list()
  local t = threads.create({ range = { start_row = 0, start_col = 0, end_row = 0, end_col = 1 }, text = '   ' })
  eq(t, nil)
  eq(#threads.list(), before)
end)

--------------------------------------------------------------------------
test('virtual lines are rendered and toggleable', function()
  fresh_buffer('render.lua', { 'one', 'two', 'three' })
  local t = threads.create({
    range = { start_row = 1, start_col = 0, end_row = 1, end_col = 3 },
    text = 'look at this',
  })
  ok(t, 'thread not created')
  local marks = vim.api.nvim_buf_get_extmarks(0, core.display_ns, 0, -1, { details = true })
  ok(#marks >= 1, 'no display extmark')
  local has_virt = false
  for _, m in ipairs(marks) do
    if m[4] and m[4].virt_lines and #m[4].virt_lines > 0 then
      has_virt = true
    end
  end
  ok(has_virt, 'display extmark has no virt_lines')
  threads.toggle()
  eq(#vim.api.nvim_buf_get_extmarks(0, core.display_ns, 0, -1, {}), 0)
  threads.toggle()
  ok(#vim.api.nvim_buf_get_extmarks(0, core.display_ns, 0, -1, {}) >= 1)
  threads.close(t)
end)

--------------------------------------------------------------------------
test('send one thread asynchronously and get an answer', function()
  fresh_buffer('send.lua', { 'alpha', 'beta' })
  local t = threads.create({
    range = { start_row = 0, start_col = 0, end_row = 0, end_col = 5 },
    text = 'What is alpha?',
  })
  threads.send(t)
  ok(wait_state(t.id, 'answered'), 'thread never answered')
  local got = threads.get(t.id)
  eq(#got.messages, 2)
  eq(got.messages[2].role, 'assistant')
  ok(got.messages[2].content:find('What is alpha%?', 1, false), 'prompt missing from answer')
end)

--------------------------------------------------------------------------
test('multi-turn reply', function()
  fresh_buffer('reply.lua', { 'alpha' })
  local t = threads.create({ range = { start_row = 0, start_col = 0, end_row = 0, end_col = 5 }, text = 'first' })
  threads.send(t)
  ok(wait_state(t.id, 'answered'), 'first turn never answered')
  threads.reply(t, { text = 'second question' })
  ok(wait_state(t.id, 'answered'), 'second turn never answered')
  local got = threads.get(t.id)
  eq(#got.messages, 4)
  eq(got.messages[3].role, 'user')
  eq(got.messages[3].content, 'second question')
  eq(got.messages[4].role, 'assistant')
end)

--------------------------------------------------------------------------
test('send all pending threads', function()
  fresh_buffer('all.lua', { 'a', 'b', 'c', 'd' })
  local t1 = threads.create({ range = { start_row = 0, start_col = 0, end_row = 0, end_col = 1 }, text = 'q1' })
  local t2 = threads.create({ range = { start_row = 2, start_col = 0, end_row = 2, end_col = 1 }, text = 'q2' })
  eq(threads.send_all(), 2)
  ok(vim.wait(5000, function()
    return threads.get(t1.id).state == 'answered' and threads.get(t2.id).state == 'answered'
  end, 20), 'threads did not both answer')
end)

--------------------------------------------------------------------------
test('editing the anchored text closes the thread', function()
  fresh_buffer('invalidate.lua', { 'keep', 'change me', 'keep too' })
  local t = threads.create({
    range = { start_row = 1, start_col = 0, end_row = 1, end_col = 9 },
    text = 'watch this line',
  })
  eq(threads.get(t.id).state, 'pending')
  vim.api.nvim_buf_set_lines(0, 1, 2, false, { 'changed' })
  ok(vim.wait(3000, function()
    return threads.get(t.id).state == 'closed'
  end, 20), 'thread was not closed after its source changed')
  ok(threads.get(t.id).closed_reason ~= nil)
end)

--------------------------------------------------------------------------
test('inserting lines above keeps the thread anchored', function()
  fresh_buffer('reanchor.lua', { 'first', 'anchor', 'last' })
  local t = threads.create({
    range = { start_row = 1, start_col = 0, end_row = 1, end_col = 6 },
    text = 'still valid?',
  })
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { '-- inserted', '-- inserted 2' })
  ok(vim.wait(3000, function()
    local got = threads.get(t.id)
    return got.state == 'pending' and got.range.start_row == 3
  end, 20), 'thread did not follow the inserted lines')
end)

--------------------------------------------------------------------------
test('persistence across buffer reload', function()
  local path = fresh_buffer('persist.lua', { 'persist', 'me' })
  local t = threads.create({ range = { start_row = 0, start_col = 0, end_row = 0, end_col = 7 }, text = 'save me' })
  local id = t.id
  vim.cmd('bwipeout!')
  vim.cmd.edit(vim.fn.fnameescape(path))
  ok(vim.wait(2000, function()
    return threads.get(id) ~= nil
  end, 20), 'thread was not reloaded from disk')
  eq(threads.get(id).state, 'pending')
end)

--------------------------------------------------------------------------
test('nav next/prev', function()
  fresh_buffer('nav.lua', { 'l1', 'l2', 'l3', 'l4', 'l5' })
  local t1 = threads.create({ range = { start_row = 1, start_col = 0, end_row = 1, end_col = 2 }, text = 'n1' })
  local t2 = threads.create({ range = { start_row = 4, start_col = 0, end_row = 4, end_col = 2 }, text = 'n2' })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  threads.next()
  eq(vim.api.nvim_win_get_cursor(0)[1], 2, 'next from top')
  threads.next()
  eq(vim.api.nvim_win_get_cursor(0)[1], 5, 'next to second')
  threads.next()
  eq(vim.api.nvim_win_get_cursor(0)[1], 2, 'next wraps')
  threads.prev()
  eq(vim.api.nvim_win_get_cursor(0)[1], 5, 'prev wraps to last')
  eq(threads.current().id, t2.id)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  eq(threads.current().id, t1.id)
end)

--------------------------------------------------------------------------
test('delete one and delete all', function()
  local path = fresh_buffer('delete.lua', { '1', '2', '3', '4' })
  local a = threads.create({ range = { start_row = 0, start_col = 0, end_row = 0, end_col = 1 }, text = 'one' })
  threads.create({ range = { start_row = 2, start_col = 0, end_row = 2, end_col = 1 }, text = 'two' })
  eq(#threads.list(), 2)
  threads.delete(a)
  eq(#threads.list(), 1)
  eq(#store.load(path).threads, 1)
  local n = threads.delete_all()
  eq(n, 1)
  eq(#threads.list(), 0)
  eq(#store.load(path).threads, 0)
end)

--------------------------------------------------------------------------
test('apply action lets the agent edit the file', function()
  local path = fresh_buffer('apply.lua', { 'local value = 1' })
  local marker = vim.fn.shellescape(path)
  threads.setup({
    storage = { dir = datadir },
    agent = {
      cmd = 'cat >/dev/null; printf "applied\\n" >> ' .. marker,
      mode = 'stdin',
    },
  })
  local t = threads.create({
    range = { start_row = 0, start_col = 0, end_row = 0, end_col = 16 },
    text = 'please apply',
  })
  threads.apply(t)
  ok(wait_state(t.id, 'answered'), 'apply thread never answered')
  ok(vim.wait(3000, function()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    return lines[#lines] == 'applied'
  end, 20), 'buffer did not pick up the agent edit')
  eq(threads.get(t.id).state, 'answered')
  threads.setup({ storage = { dir = datadir }, agent = { cmd = { 'cat' }, mode = 'stdin' } })
end)

--------------------------------------------------------------------------
test('apply that rewrites the anchored text closes the thread', function()
  local path = fresh_buffer('apply2.lua', { 'local old = 1' })
  local marker = vim.fn.shellescape(path)
  threads.setup({
    storage = { dir = datadir },
    agent = {
      cmd = 'cat >/dev/null; printf "local new = 2\\n" > ' .. marker,
      mode = 'stdin',
    },
  })
  local t = threads.create({
    range = { start_row = 0, start_col = 0, end_row = 0, end_col = 13 },
    text = 'replace it',
  })
  threads.apply(t)
  ok(vim.wait(5000, function()
    local got = threads.get(t.id)
    return got and (got.state == 'answered' or got.state == 'closed')
  end, 20), 'apply thread never answered')
  ok(vim.wait(3000, function()
    return threads.get(t.id).state == 'closed'
  end, 20), 'thread should close when the anchored text is rewritten')
  threads.setup({ storage = { dir = datadir }, agent = { cmd = { 'cat' }, mode = 'stdin' } })
end)

--------------------------------------------------------------------------
test('api.list sees threads from other files', function()
  local path = fresh_buffer('apiall.lua', { 'api' })
  local t = threads.create({ range = { start_row = 0, start_col = 0, end_row = 0, end_col = 3 }, text = 'seen?' })
  local all = threads.api.list({ all = true, include_closed = true })
  local found = false
  for _, item in ipairs(all) do
    if item.id == t.id and item.file == path then
      found = true
    end
  end
  ok(found, 'api.list({all=true}) did not find the thread')
end)

--------------------------------------------------------------------------
test('charwise single-line range keeps exact columns', function()
  fresh_buffer('charwise.lua', { 'abcdef', 'ghijkl' })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  vim.cmd('normal! vll')
  vim.cmd('normal! \27')
  local r = core.resolve_range(0, { line1 = 1, line2 = 1, had_range = true })
  eq(r.start_col, 1)
  eq(r.end_col, 4)
  eq(require('threads.util').text_in_range(0, r)[1], 'bcd')
end)

--------------------------------------------------------------------------
test('linewise visual range covers whole lines', function()
  fresh_buffer('linewise.lua', { 'abcdef', 'ghijkl', 'mnopqr' })
  vim.api.nvim_win_set_cursor(0, { 1, 2 })
  vim.cmd('normal! Vj')
  vim.cmd('normal! \27')
  local r = core.resolve_range(0, { line1 = 1, line2 = 2, had_range = true })
  eq(r.start_col, 0)
  eq(r.end_row, 1)
  local text = require('threads.util').text_in_range(0, r)
  eq(#text, 2)
  eq(text[1], 'abcdef')
  eq(text[2], 'ghijkl')
end)

--------------------------------------------------------------------------
test('user commands are registered', function()
  local cmds = vim.api.nvim_get_commands({})
  local names = {
    'ThreadNew', 'ThreadSend', 'ThreadSendAll', 'ThreadApply', 'ThreadApplyAll',
    'ThreadComment', 'ThreadReply', 'ThreadCancel', 'ThreadClose', 'ThreadToggle',
    'ThreadDelete', 'ThreadDeleteAll', 'ThreadHistory', 'ThreadShow', 'ThreadNext',
    'ThreadPrev',
  }
  for _, name in ipairs(names) do
    ok(cmds[name], 'missing command ' .. name)
  end
end)

--------------------------------------------------------------------------
test('history window opens and closes', function()
  fresh_buffer('history.lua', { 'hist' })
  threads.create({ range = { start_row = 0, start_col = 0, end_row = 0, end_col = 4 }, text = 'in history' })
  local win = threads.history()
  ok(win and vim.api.nvim_win_is_valid(win), 'history window not opened')
  vim.api.nvim_win_close(win, true)
end)

--------------------------------------------------------------------------
test('jump opens the file for a disk-only thread', function()
  local path = fresh_buffer('jump.lua', { 'j1', 'j2' })
  local t = threads.create({ range = { start_row = 1, start_col = 0, end_row = 1, end_col = 2 }, text = 'jump to me' })
  local id = t.id
  vim.cmd('bwipeout!')
  local got = threads.get(id)
  ok(got, 'thread not found on disk')
  threads.jump(got)
  eq(vim.api.nvim_buf_get_name(0), path)
  eq(vim.api.nvim_win_get_cursor(0)[1], 2)
end)

--------------------------------------------------------------------------
test('delete_all with all=true clears every file', function()
  local p1 = fresh_buffer('delall1.lua', { 'x' })
  threads.create({ range = { start_row = 0, start_col = 0, end_row = 0, end_col = 1 }, text = 'a' })
  local p2 = fresh_buffer('delall2.lua', { 'y' })
  threads.create({ range = { start_row = 0, start_col = 0, end_row = 0, end_col = 1 }, text = 'b' })
  local n = threads.delete_all({ all = true })
  ok(n >= 2, 'expected at least two deletions, got ' .. n)
  eq(#store.load(p1).threads, 0)
  eq(#store.load(p2).threads, 0)
end)

--------------------------------------------------------------------------
test('input prompt callback receives multiline text', function()
  local received
  local handle = require('threads.ui.input').prompt({
    title = 'test input',
    on_submit = function(text)
      received = text
    end,
  })
  vim.api.nvim_buf_set_lines(handle.buf, 0, -1, false, { 'line one', 'line two' })
  handle.close(true)
  vim.wait(200, function()
    return received ~= nil
  end, 10)
  eq(received, 'line one\nline two')
end)

--------------------------------------------------------------------------
test('input <Esc> submits in normal and is free in insert', function()
  local handle = require('threads.ui.input').prompt({ title = 'esc test' })
  local i_esc = vim.fn.maparg('<Esc>', 'i', false, true)
  ok(vim.tbl_isempty(i_esc), 'insert <Esc> should not be mapped')
  local n_esc = vim.fn.maparg('<Esc>', 'n', false, true)
  ok(not vim.tbl_isempty(n_esc), 'normal <Esc> should submit')
  ok(vim.tbl_isempty(vim.fn.maparg('<C-s>', 'n', false, true)) == false, '<C-s> missing in normal')
  ok(vim.tbl_isempty(vim.fn.maparg('<C-s>', 'i', false, true)) == false, '<C-s> missing in insert')
  ok(not vim.tbl_isempty(vim.fn.maparg('q', 'n', false, true)), 'q should cancel')
  handle.close(false)
end)

--------------------------------------------------------------------------
test('arg mode closes stdin so agents do not block', function()
  fresh_buffer('stdin.lua', { 'x' })
  threads.setup({
    storage = { dir = datadir },
    agent = { cmd = { 'sh', '-c', 'cat >/dev/null; echo answered' }, mode = 'arg' },
  })
  local t = threads.create({ range = { start_row = 0, start_col = 0, end_row = 0, end_col = 1 }, text = 'read stdin' })
  threads.send(t)
  ok(wait_state(t.id, 'answered', 5000), 'agent blocked on an open stdin pipe')
  threads.setup({ storage = { dir = datadir }, agent = { cmd = { 'cat' }, mode = 'stdin' } })
end)

--------------------------------------------------------------------------
test('signs indicate threads even when virtual lines are hidden', function()
  fresh_buffer('signs.lua', { 'a', 'b', 'c' })
  threads.create({ range = { start_row = 1, start_col = 0, end_row = 1, end_col = 1 }, text = 'sign me' })
  ok(#vim.api.nvim_buf_get_extmarks(0, core.sign_ns, 0, -1, {}) >= 1, 'no sign placed')
  threads.toggle()
  eq(#vim.api.nvim_buf_get_extmarks(0, core.display_ns, 0, -1, {}), 0, 'virt lines should be hidden')
  ok(#vim.api.nvim_buf_get_extmarks(0, core.sign_ns, 0, -1, {}) >= 1, 'sign should remain when collapsed')
  threads.toggle()
end)

--------------------------------------------------------------------------
test('show window uses markdown filetype', function()
  fresh_buffer('showft.lua', { 'z' })
  local t = threads.create({ range = { start_row = 0, start_col = 0, end_row = 0, end_col = 1 }, text = 'show' })
  local win = threads.show(t)
  ok(win and vim.api.nvim_win_is_valid(win), 'show window not opened')
  eq(vim.bo[vim.api.nvim_win_get_buf(win)].filetype, 'markdown')
  vim.api.nvim_win_close(win, true)
end)

--------------------------------------------------------------------------
test('comment() aggregates messages before sending', function()
  fresh_buffer('comment.lua', { 'x', 'y' })
  threads.setup({ storage = { dir = datadir }, agent = { cmd = { 'cat' }, mode = 'stdin' } })
  local t = threads.create({ range = { start_row = 0, start_col = 0, end_row = 0, end_col = 1 }, text = 'first' })
  threads.comment(t, { text = 'second' })
  threads.comment(t, { text = 'third' })
  eq(#threads.get(t.id).messages, 3)
  eq(threads.get(t.id).state, 'pending')
  threads.send(t)
  ok(wait_state(t.id, 'answered'), 'thread with aggregated comments never answered')
  eq(#threads.get(t.id).messages, 4)
end)

--------------------------------------------------------------------------
test('create() from a visual mapping uses the whole selection', function()
  fresh_buffer('visualsel.lua', { 'l1', 'l2', 'l3', 'l4', 'l5', 'l6' })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd('normal! Vjj') -- linewise selection over lines 2-4
  vim.cmd('normal! \27')
  local t = threads.create({ text = 'whole selection' }) -- like a :<C-u> mapping
  ok(t, 'thread not created')
  eq(t.range.start_row, 1)
  eq(t.range.end_row, 3)
  eq(t.range.start_col, 0)
end)

--------------------------------------------------------------------------
test('create() from a charwise selection keeps columns', function()
  fresh_buffer('visualchar.lua', { 'abcdef', 'ghijkl' })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  vim.cmd('normal! vll')
  vim.cmd('normal! \27')
  local t = threads.create({ text = 'chars' })
  ok(t, 'thread not created')
  eq(t.range.start_row, 0)
  eq(t.range.start_col, 1)
  eq(t.range.end_col, 4)
  eq(require('threads.util').text_in_range(0, t.range)[1], 'bcd')
end)

--------------------------------------------------------------------------

print(('\n%d passed, %d failed'):format(passed, #failures))
if #failures > 0 then
  print(table.concat(failures, '\n\n'))
  vim.cmd('cquit 1')
end
vim.cmd('qa!')
