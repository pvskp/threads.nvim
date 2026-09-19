-- threads.nvim: user commands only. No keymaps are set here on purpose.
if vim.g.loaded_threads_nvim then
  return
end
vim.g.loaded_threads_nvim = true

if vim.fn.has('nvim-0.10') ~= 1 then
  vim.notify('threads.nvim requires Neovim >= 0.10', vim.log.levels.ERROR)
  return
end

local function threads()
  return require('threads')
end

local function complete_ids(arglead)
  local ok, list = pcall(function()
    return threads().api.list({ all = true, include_closed = true })
  end)
  if not ok or type(list) ~= 'table' then
    return {}
  end
  local out = {}
  for _, t in ipairs(list) do
    if t.id:sub(1, #arglead) == arglead then
      out[#out + 1] = t.id
    end
  end
  return out
end

local function resolve(args)
  if args.args ~= nil and args.args ~= '' then
    return threads().get(args.args)
  end
  return threads().current()
end

vim.api.nvim_create_user_command('ThreadNew', function(args)
  threads().create({
    line1 = args.line1,
    line2 = args.line2,
    had_range = args.range == 2,
    bang = args.bang,
  })
end, {
  range = true,
  bang = true,
  desc = 'threads.nvim: create a thread on the selection (bang = create and send)',
})

vim.api.nvim_create_user_command('ThreadSend', function(args)
  local t = resolve(args)
  if not t then
    vim.notify('threads.nvim: no thread here', vim.log.levels.WARN)
    return
  end
  threads().send(t, { action = args.bang and 'apply' or nil })
end, {
  nargs = '?',
  bang = true,
  complete = complete_ids,
  desc = 'threads.nvim: send one thread (bang = apply changes)',
})

vim.api.nvim_create_user_command('ThreadSendAll', function(args)
  threads().send_all({ all = args.args == 'all' })
end, {
  nargs = '?',
  complete = function(arglead)
    if ('all'):sub(1, #arglead) == arglead then
      return { 'all' }
    end
    return {}
  end,
  desc = 'threads.nvim: send all pending threads in the buffer (or "all" files)',
})

vim.api.nvim_create_user_command('ThreadApply', function(args)
  local t = resolve(args)
  if not t then
    vim.notify('threads.nvim: no thread here', vim.log.levels.WARN)
    return
  end
  threads().apply(t)
end, {
  nargs = '?',
  complete = complete_ids,
  desc = 'threads.nvim: ask the agent to apply changes directly to the file',
})

vim.api.nvim_create_user_command('ThreadApplyAll', function(args)
  threads().apply_all({ all = args.args == 'all' })
end, { nargs = '?', desc = 'threads.nvim: apply all pending threads' })

vim.api.nvim_create_user_command('ThreadReply', function(args)
  local t = resolve(args)
  if not t then
    vim.notify('threads.nvim: no thread here', vim.log.levels.WARN)
    return
  end
  threads().reply(t)
end, {
  nargs = '?',
  complete = complete_ids,
  desc = 'threads.nvim: add a follow-up message and send it',
})

vim.api.nvim_create_user_command('ThreadCancel', function(args)
  local t = resolve(args)
  if not t then
    vim.notify('threads.nvim: no thread here', vim.log.levels.WARN)
    return
  end
  threads().cancel(t)
end, { nargs = '?', complete = complete_ids, desc = 'threads.nvim: cancel a running request' })

vim.api.nvim_create_user_command('ThreadClose', function(args)
  local t = resolve(args)
  if not t then
    vim.notify('threads.nvim: no thread here', vim.log.levels.WARN)
    return
  end
  threads().close(t)
end, { nargs = '?', complete = complete_ids, desc = 'threads.nvim: close a thread manually' })

vim.api.nvim_create_user_command('ThreadToggle', function(args)
  threads().toggle(args.bang)
end, { bang = true, desc = 'threads.nvim: toggle thread display (bang = all buffers)' })

vim.api.nvim_create_user_command('ThreadDelete', function(args)
  local t = resolve(args)
  if not t then
    vim.notify('threads.nvim: no thread here', vim.log.levels.WARN)
    return
  end
  threads().delete(t)
end, { nargs = '?', complete = complete_ids, desc = 'threads.nvim: delete one thread' })

vim.api.nvim_create_user_command('ThreadDeleteAll', function(args)
  threads().delete_all({ all = args.bang or args.args == 'all' })
end, {
  nargs = '?',
  bang = true,
  desc = 'threads.nvim: delete all threads in the buffer (bang or "all" = every file)',
})

vim.api.nvim_create_user_command('ThreadHistory', function(args)
  threads().history({ all = args.args == 'all' })
end, { nargs = '?', desc = 'threads.nvim: open the threads history window' })

vim.api.nvim_create_user_command('ThreadShow', function(args)
  local t = resolve(args)
  if not t then
    vim.notify('threads.nvim: no thread here', vim.log.levels.WARN)
    return
  end
  threads().show(t)
end, { nargs = '?', complete = complete_ids, desc = 'threads.nvim: open a thread in a floating window' })

vim.api.nvim_create_user_command('ThreadNext', function()
  threads().next()
end, { desc = 'threads.nvim: jump to the next thread' })

vim.api.nvim_create_user_command('ThreadPrev', function()
  threads().prev()
end, { desc = 'threads.nvim: jump to the previous thread' })

-- Activate autocmds/highlights on startup so threads appear without any command.
threads()._ensure()
