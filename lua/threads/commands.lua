-- threads.nvim: user command definitions.
--
-- Kept in a Lua module (instead of only plugin/threads.lua) so the commands are
-- registered by `require('threads').setup()` / first API call even when the
-- plugin directory is added to 'runtimepath' after plugin scanning (a common
-- dev setup: `vim.opt.runtimepath:prepend(...)` inside a plugin/*.lua file).
local M = {}

local registered = false

local function threads()
  return require('threads')
end

local function notify(msg)
  vim.notify('threads.nvim: ' .. msg, vim.log.levels.WARN)
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

local function with_thread(args, fn)
  local t = resolve(args)
  if not t then
    notify('no thread here')
    return
  end
  fn(t)
end

function M.register()
  if registered then
    return
  end
  registered = true

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
    with_thread(args, function(t)
      threads().send(t, { action = args.bang and 'apply' or nil })
    end)
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
    with_thread(args, function(t)
      threads().apply(t)
    end)
  end, {
    nargs = '?',
    complete = complete_ids,
    desc = 'threads.nvim: ask the agent to apply changes directly to the file',
  })

  vim.api.nvim_create_user_command('ThreadApplyAll', function(args)
    threads().apply_all({ all = args.args == 'all' })
  end, { nargs = '?', desc = 'threads.nvim: apply all pending threads' })

  vim.api.nvim_create_user_command('ThreadComment', function(args)
    with_thread(args, function(t)
      threads().comment(t)
    end)
  end, {
    nargs = '?',
    complete = complete_ids,
    desc = 'threads.nvim: add a comment to a thread without sending it',
  })

  vim.api.nvim_create_user_command('ThreadReply', function(args)
    with_thread(args, function(t)
      threads().reply(t)
    end)
  end, {
    nargs = '?',
    complete = complete_ids,
    desc = 'threads.nvim: add a follow-up message and send it',
  })

  vim.api.nvim_create_user_command('ThreadCancel', function(args)
    with_thread(args, function(t)
      threads().cancel(t)
    end)
  end, { nargs = '?', complete = complete_ids, desc = 'threads.nvim: cancel a running request' })

  vim.api.nvim_create_user_command('ThreadClose', function(args)
    with_thread(args, function(t)
      threads().close(t)
    end)
  end, { nargs = '?', complete = complete_ids, desc = 'threads.nvim: close a thread manually' })

  vim.api.nvim_create_user_command('ThreadToggle', function(args)
    threads().toggle(args.bang)
  end, { bang = true, desc = 'threads.nvim: toggle thread display (bang = all buffers)' })

  vim.api.nvim_create_user_command('ThreadDelete', function(args)
    with_thread(args, function(t)
      threads().delete(t)
    end)
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
    with_thread(args, function(t)
      threads().show(t, { window = args.bang and 'split' or nil })
    end)
  end, {
    nargs = '?',
    bang = true,
    complete = complete_ids,
    desc = 'threads.nvim: open a thread (bang = split window)',
  })

  vim.api.nvim_create_user_command('ThreadExpand', function(args)
    with_thread(args, function(t)
      threads().toggle_expand(t)
    end)
  end, {
    nargs = '?',
    complete = complete_ids,
    desc = 'threads.nvim: expand/collapse the thread inline',
  })

  vim.api.nvim_create_user_command('ThreadNext', function()
    threads().next()
  end, { desc = 'threads.nvim: jump to the next thread' })

  vim.api.nvim_create_user_command('ThreadPrev', function()
    threads().prev()
  end, { desc = 'threads.nvim: jump to the previous thread' })
end

return M
