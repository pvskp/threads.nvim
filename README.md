# threads.nvim

Interactive threads around text objects, backed by any LLM agent CLI you
already have installed (`opencode`, `codex`, `claude`, `pi`, ...).

Select some code, leave a comment, keep working. Later, send one thread or all
of them to your agent. Answers show up inline as virtual lines, edits are made
by the agent itself. Nothing is ever written into your files.

```
  12  local cached = compute(input)          <- your code
      ▌ ● thread a1b2c3d4 [answered]
        ▸ you: is this cache safe with nil input?
        ◆ opencode: No, guard before the lookup...
```

## Requirements

- Neovim >= 0.10
- Any agent CLI that can run non-interactively (see [Agents](#agents))

## Install

With `lazy.nvim`:

```lua
{
  'pvskp/threads.nvim',
  config = function()
    require('threads').setup({
      agent = { cmd = { 'opencode', 'run', '--auto' } },
    })
  end,
}
```

With Neovim 0.12 `vim.pack`:

```lua
vim.pack.add({ 'https://github.com/pvskp/threads.nvim' })
require('threads').setup()
```

No keymaps are set by default. Suggested maps:

```lua
vim.keymap.set('n', ']r', function() require('threads').next() end, { desc = 'Next thread' })
vim.keymap.set('n', '[r', function() require('threads').prev() end, { desc = 'Previous thread' })
vim.keymap.set('v', '<leader>tc', ":<C-u>lua require('threads').create()<CR>", { desc = 'Comment on selection' })
vim.keymap.set('n', '<leader>ts', function() require('threads').send() end, { desc = 'Send thread' })
vim.keymap.set('n', '<leader>tS', function() require('threads').send_all() end, { desc = 'Send all threads' })
vim.keymap.set('n', '<leader>tr', function() require('threads').reply() end, { desc = 'Reply in thread' })
vim.keymap.set('n', '<leader>ta', function() require('threads').apply() end, { desc = 'Apply thread changes' })
vim.keymap.set('n', '<leader>tt', function() require('threads').toggle() end, { desc = 'Toggle threads' })
vim.keymap.set('n', '<leader>th', function() require('threads').history() end, { desc = 'Threads history' })
vim.keymap.set('n', '<leader>td', function() require('threads').delete() end, { desc = 'Delete thread' })
vim.keymap.set('n', '<leader>tD', function() require('threads').delete_all() end, { desc = 'Delete all threads' })
```

## Workflow

1. Select code in visual mode, run `:'<,'>ThreadNew` (or your map). A floating
   window asks for a comment. Type it and submit with `<C-s>`, or press
   `<Esc>` to go to normal mode and `<Esc>` again to submit (`q` cancels).
   The thread is stored as `pending`.
2. Repeat on other ranges. Threads render under their lines, nothing is written
   to disk in the repo.
3. `:ThreadSend` sends the thread under the cursor. `:ThreadSendAll` sends
   every pending thread in the buffer (`:ThreadSendAll all` = every file) - all
   requests run concurrently, Neovim stays responsive. Need to add more first?
   Use `:ThreadComment` (appends without sending) as many times as you want,
   then send once.
4. Waiting threads show an animated spinner. When done, the answer is appended
   to the thread (`answered`) and a notification is shown.
5. `:ThreadReply` adds a follow-up message and sends it (multi-turn).
6. `:ThreadApply` asks the agent to edit the file itself for that thread.
   The whole file is included in every prompt for context.

## Commands

| Command | Description |
| --- | --- |
| `:ThreadNew` | Create a thread on the current line / visual range. `:ThreadNew!` also sends it. |
| `:ThreadSend [id]` | Send one thread (cursor or id). Bang = apply mode. |
| `:ThreadSendAll [all]` | Send all pending threads (buffer, or `all` files). |
| `:ThreadComment [id]` | Add a comment/question to a thread without sending it. |
| `:ThreadReply [id]` | Add a message to a thread and send it. |
| `:ThreadApply [id]` | Send a thread in apply mode: the agent edits the file. |
| `:ThreadApplyAll [all]` | Apply mode for all pending threads. |
| `:ThreadCancel [id]` | Stop a running request. |
| `:ThreadClose [id]` | Close a thread manually. |
| `:ThreadToggle` | Hide/show threads in the buffer (`!` = all buffers). |
| `:ThreadDelete [id]` | Delete one thread. |
| `:ThreadDeleteAll [all]` | Delete all threads in the buffer (`!`/`all` = every file). |
| `:ThreadHistory [all]` | Interactive window with all threads, closed ones included. |
| `:ThreadShow [id]` | Full conversation in a floating window (`!` = split, navigable/searchable). |
| `:ThreadExpand [id]` | Expand/collapse the thread inline (show all message lines). |
| `:ThreadNext` / `:ThreadPrev` | Jump between threads. |

Commands accept full ids or unique id prefixes with completion.

Inside `:ThreadHistory`: `<CR>` jump, `o` open, `d` delete, `q` quit.

Inside a thread view (`:ThreadShow`, `:ThreadShow!`): `[[` / `]]` jump between
messages, `q` closes. The view uses `filetype=markdown` with conceal enabled, so
the markup is rendered while you can still navigate, search and yank.

## Configuration

```lua
require('threads').setup({
  storage = {
    dir = vim.fn.stdpath('data') .. '/threads.nvim', -- one JSON per source file, hashed path
    max_threads = 300,                               -- oldest closed threads are pruned
  },
  reanchor_lines = 200, -- how far to look for the anchored text after external changes

  agent = {
    name = nil,     -- label shown in the threads
    cmd = nil,      -- nil = auto-detect (see below)
    mode = 'arg',   -- 'arg' (prompt appended) | 'stdin' (prompt piped)
    cwd = nil,      -- string or function(ctx) -> string; defaults to the file's directory
    env = {},       -- extra environment variables
    timeout = 0,    -- ms; 0 disables
    autodetect = true,
    autodetect_order = { 'opencode', 'codex', 'claude', 'pi' },
  },

  display = {
    enabled = true,
    signs = true,             -- sign-column indicator even when lines are hidden
    markdown = true,          -- conceal markdown markup and style the text
    show_closed = false,      -- closed threads stay in :ThreadHistory
    max_message_lines = 8,    -- lines per message before "… more"
    max_lines = 30,           -- total virtual lines per thread
    padding = '  ',
  },

  input = { width = 0.6, height = 4, border = 'rounded' },
  show = {
    window = 'float',  -- 'float' | 'split'
    conceal = true,    -- conceal markdown markup in the view
    width = 0.8,
    height = 0.8,
    border = 'rounded',
    split = 'below',   -- 'below' | 'above' | 'left' | 'right'
    split_size = 0.4,
  },
  history = { width = 0.85, height = 0.8, border = 'rounded' },

  -- Optional: set these and threads.nvim maps them for you. Nothing is mapped by default.
  keymaps = { next = ']r', prev = '[r' },

  icons = { pending = '○', sent = '◌', answered = '●', closed = '✕', error = '!' },
})
```

### Agents

`agent.cmd` can be:

- a **table** (argv). With `mode = "arg"` the prompt is appended as the last
  argument; with `mode = "stdin"` it is piped to the process.
- a **string**: a shell command that receives the prompt on stdin.
- a **function(prompt, ctx) -> argv | string** for full control, where `ctx` is
  `{ whole_file = string, thread = ... }`.

Examples:

```lua
-- opencode
agent = { cmd = { 'opencode', 'run', '--auto' }, mode = 'arg' }

-- claude code (non-interactive)
agent = { cmd = 'claude -p --permission-mode acceptEdits', mode = 'stdin' }

-- codex
agent = { cmd = { 'codex', 'exec', '--full-auto' }, mode = 'stdin' }

-- pi
agent = { cmd = { 'pi', '-p' }, mode = 'arg' }

-- custom wrapper that writes the prompt to a temp file
agent = {
  cmd = function(prompt)
    return { 'my-agent', '--file', '/dev/stdin' }
  end,
  mode = 'stdin',
}
```

Auto-detection tries `autodetect_order` against `$PATH` when `cmd` is nil.

### Apply mode and edits

`apply` actions tell the agent to edit the file directly with its own tools.
Neovim does not review diffs. When the process finishes successfully the
plugin runs `:checktime`; if the buffer has unsaved changes it warns instead of
clobbering them. Edits that change the anchored text close the thread
automatically (it lives on in the history).

## Lua API

```lua
local threads = require('threads')

threads.create({ range = { start_row, start_col, end_row, end_col }, text = 'why?' })
threads.send(t, { action = 'ask' | 'apply' })
threads.send_all({ all = false, action = 'ask' })
threads.reply(t, { text = 'follow up' })
threads.comment(t, { text = 'another note' }) -- append without sending
threads.apply(t)
threads.cancel(t)
threads.close(t)
threads.delete(t)
threads.delete_all({ all = false })
threads.toggle(all)
threads.current()            -- thread under the cursor
threads.get(id)              -- by full id or unique prefix (searches disk too)
threads.list(opts)           -- opts: { bufnr, all, include_closed, sort = 'updated' }
threads.next() / threads.prev()
threads.jump(t)              -- focus the file and place the cursor
threads.show(t)              -- conversation (opts.window = "float" | "split")
threads.expand(t, true)      -- expand/collapse inline
threads.toggle_expand(t)
threads.history({ all = false })
threads.status()             -- { pending, sent, answered, closed, error, total }
threads.statusline()         -- compact string for statuslines
```

`threads.api` exposes the same read helpers (`list`, `get`, `current`, `jump`,
`show`, `status`, `events`) for picker integrations.

### Events

```lua
local id = threads.on('answered', function(t) ... end)
threads.off(id)
```

Events: `created`, `sent`, `answered`, `error`, `closed`, `canceled`,
`commented`, `expanded`, `deleted`, `cleared`, `toggled`, `jumped`. They also
fire as `User ThreadsAnswered`, etc.

### Telescope picker example

```lua
vim.keymap.set('n', '<leader>tf', function()
  local pickers = require('telescope.pickers')
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')
  local threads = require('threads')

  local items = threads.api.list({ all = true, include_closed = true, sort = 'updated' })
  pickers.new({}, {
    prompt_title = 'Threads',
    finder = finders.new_table({
      results = items,
      entry_maker = function(t)
        return {
          value = t,
          display = ('%s [%s] %s:%d  %s'):format(
            t.id:sub(1, 8), t.state,
            vim.fn.fnamemodify(t.file, ':t'), t.range.start_row + 1, t.preview),
          ordinal = t.state .. ' ' .. t.preview,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        threads.jump(threads.get(entry.value.id))
      end)
      return true
    end,
  }):find()
end)
```

### lualine

```lua
{ function() return require('threads').statusline() end }
```

## How it works

- Each source file gets one JSON file at
  `stdpath('data')/threads.nvim/<sha256(path)>.json`. Threads never touch the
  repository.
- Anchors are tracked with extmarks; rendering uses `virt_lines`, so the buffer
  text is untouched. Signs in the sign column mark every thread even when
  `:ThreadToggle` hides the virtual lines.
- Answers are rendered as markdown: the markup is concealed and the text styled
  (`**bold**`, `` `code` ``, headings, lists, quotes, fenced code). Turn it off
  with `display = { markdown = false }`.
- Editing the anchored text closes the thread (`closed`), keeping history.
  Inserting lines above/below moves the anchor instead.
- Requests are plain `jobstart` processes: fully asynchronous and concurrent.
- A thread is a multi-turn conversation with states `pending`, `sent`,
  `answered`, `closed`, `error`.

## Tests

```sh
make test
```
