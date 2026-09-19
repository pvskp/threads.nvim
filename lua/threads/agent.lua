-- threads.nvim: build prompts and run the user's agent asynchronously
local config = require('threads.config')
local util = require('threads.util')

local M = {}

--- Pick the first known agent available on PATH.
function M.detect()
  local cfg = config.get().agent
  if not cfg.autodetect then
    return nil
  end
  for _, name in ipairs(cfg.autodetect_order or {}) do
    local known = config.known_agents[name]
    if known and vim.fn.executable(known.cmd[1]) == 1 then
      return vim.deepcopy(known)
    end
  end
  return nil
end

--- Resolve the configured agent (falls back to autodetection), or nil.
function M.resolve()
  local cfg = config.get().agent
  if cfg.cmd then
    local mode = cfg.mode or 'arg'
    if type(cfg.cmd) == 'string' then
      mode = 'stdin'
    end
    return {
      name = cfg.name or 'agent',
      cmd = cfg.cmd,
      mode = mode,
      cwd = cfg.cwd,
      env = cfg.env,
      timeout = cfg.timeout,
    }
  end
  local detected = M.detect()
  if detected then
    if cfg.name then
      detected.name = cfg.name
    end
    detected.cwd = cfg.cwd
    detected.env = cfg.env
    detected.timeout = cfg.timeout
    return detected
  end
  return nil
end

local function code_block(text, ftype)
  return '```' .. (ftype or '') .. '\n' .. text .. '\n```'
end

local function transcript(t)
  local parts = {}
  for _, m in ipairs(t.messages or {}) do
    local who = m.role == 'user' and 'User' or 'Assistant'
    parts[#parts + 1] = who .. ': ' .. (m.content or '')
  end
  return table.concat(parts, '\n\n')
end

--- Build the full prompt handed to the agent for this turn.
function M.build_prompt(t, ctx)
  ctx = ctx or {}
  local ftype = (t.ft and t.ft ~= '') and t.ft or 'text'
  local parts = {}

  parts[#parts + 1] = 'You are a coding assistant invoked from Neovim by the threads.nvim plugin.'
  parts[#parts + 1] = 'File under discussion: ' .. t.file
  parts[#parts + 1] = ('The thread is anchored to lines %d-%d of that file. '
    .. 'The selected text at thread creation was:\n%s'):format(
    t.range.start_row + 1,
    t.range.end_row + 1,
    code_block(table.concat(t.snapshot or {}, '\n'), ftype)
  )

  if ctx.whole_file and ctx.whole_file ~= '' then
    parts[#parts + 1] = 'Full content of the file when this request was made (for context):\n'
      .. code_block(ctx.whole_file, ftype)
  end

  parts[#parts + 1] = 'Conversation so far:\n' .. transcript(t)

  if t.action == 'apply' then
    parts[#parts + 1] = 'Task: the user asked for changes. Apply them directly to the file on disk '
      .. 'using your editing tools. Make the edits yourself - do not just print a diff or instructions. '
      .. 'When done, reply with a short summary of what you changed.'
  else
    parts[#parts + 1] = 'Task: answer the last user message. Be concise and specific. Do not modify any files.'
  end

  return table.concat(parts, '\n\n')
end

--- Line collector for jobstart output streams.
local function collector()
  local acc = {}
  local partial = ''
  return {
    on_data = function(_, data)
      if not data or vim.tbl_isempty(data) then
        return
      end
      data[1] = partial .. data[1]
      partial = table.remove(data) or ''
      vim.list_extend(acc, data)
    end,
    text = function()
      local lines = vim.deepcopy(acc)
      if partial ~= '' then
        lines[#lines + 1] = partial
      end
      return table.concat(lines, '\n')
    end,
  }
end

--- Run the agent for thread `t`.
--- ctx = { whole_file = string, on_exit = fun(result) }
--- Returns a handle ({ job, stop }) or nil, err.
function M.run(t, ctx)
  ctx = ctx or {}
  local spec = M.resolve()
  if not spec then
    return nil, 'no agent command configured. Set agent.cmd in require("threads").setup() '
      .. 'or install one of: '
      .. table.concat(config.get().agent.autodetect_order or {}, ', ')
  end

  local prompt = M.build_prompt(t, ctx)
  local cmd = spec.cmd
  if type(cmd) == 'function' then
    cmd = cmd(prompt, ctx)
  end
  if type(cmd) == 'string' then
    spec.mode = 'stdin'
    cmd = { 'sh', '-c', cmd }
  end
  if type(cmd) ~= 'table' or #cmd == 0 then
    return nil, 'invalid agent command'
  end
  cmd = vim.deepcopy(cmd)
  if spec.mode ~= 'stdin' then
    cmd[#cmd + 1] = prompt
  end

  local cwd = spec.cwd
  if type(cwd) == 'function' then
    cwd = cwd(ctx)
  end
  if not cwd or vim.fn.isdirectory(cwd) == 0 then
    cwd = vim.fn.fnamemodify(t.file, ':h')
    if vim.fn.isdirectory(cwd) == 0 then
      cwd = nil
    end
  end

  local env = spec.env
  if type(env) == 'function' then
    env = env(ctx)
  end
  if type(env) == 'table' and vim.tbl_isempty(env) then
    env = nil
  end

  local stdout = collector()
  local stderr = collector()
  local handle = { done = false, timed_out = false, job = nil }

  local ok, job = pcall(vim.fn.jobstart, cmd, {
    cwd = cwd,
    env = env,
    stdin = spec.mode == 'stdin' and 'pipe' or 'null',
    on_stdout = function(_, data)
      stdout.on_data(_, data)
    end,
    on_stderr = function(_, data)
      stderr.on_data(_, data)
    end,
    on_exit = function(_, code)
      handle.done = true
      if ctx.on_exit then
        ctx.on_exit({
          code = code,
          stdout = stdout.text(),
          stderr = stderr.text(),
          timed_out = handle.timed_out,
        })
      end
    end,
  })
  if not ok or type(job) ~= 'number' or job <= 0 then
    return nil, 'could not start agent command: ' .. table.concat(cmd, ' ')
  end

  handle.job = job
  if spec.mode == 'stdin' then
    vim.fn.chansend(job, prompt)
    vim.fn.chanclose(job, 'stdin')
  end
  if spec.timeout and spec.timeout > 0 then
    vim.defer_fn(function()
      if not handle.done then
        handle.timed_out = true
        pcall(vim.fn.jobstop, job)
      end
    end, spec.timeout)
  end
  handle.stop = function()
    if not handle.done then
      handle.done = true
      pcall(vim.fn.jobstop, job)
    end
  end
  return handle
end

M._collector = collector
return M
