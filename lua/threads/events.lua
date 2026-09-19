-- threads.nvim: tiny event bus + `User Threads*` autocmds for integrations
local M = { handlers = {}, next_id = 0 }

function M.on(name, fn)
  if type(fn) ~= 'function' then
    return nil
  end
  M.next_id = M.next_id + 1
  local id = M.next_id
  M.handlers[name] = M.handlers[name] or {}
  table.insert(M.handlers[name], { id = id, fn = fn })
  return id
end

function M.off(id)
  for _, list in pairs(M.handlers) do
    for i, h in ipairs(list) do
      if h.id == id then
        table.remove(list, i)
        return true
      end
    end
  end
  return false
end

local function autocmd_name(name)
  return 'Threads' .. name:sub(1, 1):upper() .. name:sub(2)
end

function M.emit(name, data)
  for _, h in ipairs(M.handlers[name] or {}) do
    local ok, err = pcall(h.fn, data)
    if not ok then
      vim.schedule(function()
        vim.notify('threads.nvim: event handler error: ' .. tostring(err), vim.log.levels.ERROR)
      end)
    end
  end
  vim.schedule(function()
    pcall(vim.api.nvim_exec_autocmds, 'User', {
      pattern = autocmd_name(name),
      data = data,
    })
  end)
end

return M
