-- threads.nvim: configuration with sane defaults
local M = {}

M.defaults = {
  -- Where threads are persisted. Never inside the repo.
  storage = {
    dir = vim.fn.stdpath('data') .. '/threads.nvim',
    -- Oldest closed threads are pruned when a file exceeds this many threads.
    max_threads = 300,
  },

  -- How far to look for the anchored text when a file changed while closed.
  reanchor_lines = 200,

  -- Agent process used for requests. `cmd = nil` means auto-detect.
  agent = {
    name = nil,
    -- string  -> shell command, prompt is written to stdin
    -- table   -> argv, prompt appended (mode = "arg") or piped (mode = "stdin")
    -- function(prompt, ctx) -> argv | shell string, fully custom
    cmd = nil,
    mode = 'arg', -- "arg" | "stdin"
    cwd = nil, -- string | function(ctx) -> string
    env = {}, -- table | function(ctx) -> table
    timeout = 0, -- ms; 0 disables
    autodetect = true,
    autodetect_order = { 'opencode', 'codex', 'claude', 'pi' },
  },

  display = {
    enabled = true,
    -- Show state signs in the sign column (an indicator even when virtual
    -- lines are hidden with :ThreadToggle).
    signs = true,
    -- Closed threads are hidden from the buffer by default (they live on in :ThreadHistory).
    show_closed = false,
    max_message_lines = 8,
    max_lines = 30,
    padding = '  ',
  },

  input = { width = 0.6, height = 4, border = 'rounded' },
  show = { width = 0.8, height = 0.8, border = 'rounded' },
  history = { width = 0.85, height = 0.8, border = 'rounded' },

  -- Optional convenience keymaps. Nothing is mapped unless you set this table.
  -- Example: { next = ']r', prev = '[r', new = '<leader>tn', ... }
  keymaps = nil,

  icons = {
    pending = '○',
    sent = '◌',
    answered = '●',
    closed = '✕',
    error = '!',
  },
}

-- Known non-interactive invocations for common agents.
-- These are starting points; override `agent.cmd` if your CLI differs.
M.known_agents = {
  opencode = { name = 'opencode', cmd = { 'opencode', 'run', '--auto' }, mode = 'arg' },
  codex = { name = 'codex', cmd = { 'codex', 'exec', '--full-auto' }, mode = 'stdin' },
  claude = { name = 'claude', cmd = { 'claude', '-p', '--permission-mode', 'acceptEdits' }, mode = 'stdin' },
  pi = { name = 'pi', cmd = { 'pi', '-p' }, mode = 'arg' },
}

local current = nil

function M.setup(opts)
  opts = opts or {}
  local merged = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts)
  if type(merged.agent.cmd) == 'string' then
    merged.agent.mode = 'stdin'
  end
  current = merged
  return current
end

function M.get()
  if not current then
    current = vim.deepcopy(M.defaults)
  end
  return current
end

function M.reset()
  current = vim.deepcopy(M.defaults)
end

return M
