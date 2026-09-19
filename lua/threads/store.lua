-- threads.nvim: JSON persistence in stdpath('data')/threads.nvim/<hash>.json
local config = require('threads.config')
local util = require('threads.util')

local M = {}

local function dir()
  return config.get().storage.dir
end

function M.ensure_dir()
  local d = dir()
  if vim.fn.isdirectory(d) == 0 then
    vim.fn.mkdir(d, 'p')
  end
  return d
end

function M.path_for(file)
  return dir() .. '/' .. util.sha(file):sub(1, 24) .. '.json'
end

local function decode(path)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= 'table' then
    return nil
  end
  local ok2, data = pcall(vim.json.decode, table.concat(lines, '\n'))
  if not ok2 or type(data) ~= 'table' or type(data.threads) ~= 'table' then
    return nil
  end
  return data
end

function M.load(file)
  local data = decode(M.path_for(file))
  if not data then
    return { version = 1, path = file, threads = {} }
  end
  return data
end

function M.save(file, data)
  M.ensure_dir()
  data.version = data.version or 1
  data.path = file
  data.updated_at = os.time()
  local ok, encoded = pcall(vim.json.encode, data)
  if not ok then
    util.notify('could not encode threads: ' .. tostring(encoded), vim.log.levels.ERROR)
    return false
  end
  local target = M.path_for(file)
  local tmp = target .. '.tmp'
  local wrote = pcall(vim.fn.writefile, { encoded }, tmp)
  if not wrote then
    return false
  end
  local renamed = vim.uv.fs_rename(tmp, target)
  if not renamed then
    pcall(vim.fn.writefile, { encoded }, target)
  end
  return true
end

function M.delete(file)
  local p = M.path_for(file)
  if vim.fn.filereadable(p) == 1 then
    vim.fn.delete(p)
  end
end

function M.files()
  M.ensure_dir()
  return vim.fn.glob(dir() .. '/*.json', false, true)
end

--- All thread files on disk. Each entry: { path = <source file>, threads = {...} }
function M.load_all()
  local out = {}
  for _, path in ipairs(M.files()) do
    local data = decode(path)
    if data and type(data.path) == 'string' then
      out[#out + 1] = data
    end
  end
  return out
end

return M
