-- threads.nvim: public API
--
-- Most functions are safe to call from any buffer; commands that operate on
-- "the current thread" resolve it from the cursor position.
local config = require('threads.config')
local core = require('threads.core')
local events = require('threads.events')

local M = {}

local setup_done = false

local function ensure()
  if not setup_done then
    setup_done = true
    core.setup()
  end
end

--- Configure the plugin. Calling this is optional; defaults auto-detect an agent.
function M.setup(opts)
  config.setup(opts)
  if not setup_done then
    setup_done = true
    core.setup()
  else
    core.apply_keymaps()
    require('threads.render').define_highlights()
  end
  return config.get()
end

--- @private used by plugin/threads.lua to activate autocmds early.
function M._ensure()
  ensure()
end

function M.create(...)
  ensure()
  return core.create(...)
end

function M.comment(...)
  ensure()
  return core.comment(...)
end

function M.reply(...)
  ensure()
  return core.reply(...)
end

function M.send(...)
  ensure()
  return core.send(...)
end

function M.send_all(...)
  ensure()
  return core.send_all(...)
end

function M.apply(...)
  ensure()
  return core.apply(...)
end

function M.apply_all(...)
  ensure()
  return core.apply_all(...)
end

function M.cancel(...)
  ensure()
  return core.cancel(...)
end

function M.close(...)
  ensure()
  return core.close(...)
end

function M.delete(...)
  ensure()
  return core.delete(...)
end

function M.delete_all(...)
  ensure()
  return core.delete_all(...)
end

function M.toggle(...)
  ensure()
  return core.toggle(...)
end

function M.current(...)
  ensure()
  return core.current(...)
end

function M.get(...)
  ensure()
  return core.get(...)
end

function M.list(...)
  ensure()
  return core.list(...)
end

function M.next(...)
  ensure()
  return core.next(...)
end

function M.prev(...)
  ensure()
  return core.prev(...)
end

function M.jump(...)
  ensure()
  return core.jump(...)
end

function M.show(...)
  ensure()
  return core.show(...)
end

function M.history(...)
  ensure()
  return core.history(...)
end

function M.status(...)
  ensure()
  return core.status(...)
end

function M.statusline(...)
  ensure()
  return core.statusline(...)
end

--- Event bus: on("created"|"sent"|"answered"|"error"|"closed"|"deleted"|"cleared"|"toggled"|"jumped"|"canceled", fn)
M.on = events.on
M.off = events.off

--- Read-only view helpers for picker integrations (telescope, fzf-lua, snacks, ...).
M.api = {
  list = M.list,
  get = M.get,
  current = M.current,
  jump = M.jump,
  show = M.show,
  status = M.status,
  events = events,
}

function M.config()
  return config.get()
end

return M
