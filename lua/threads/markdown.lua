-- threads.nvim: lightweight markdown -> virt_line chunks.
--
-- virt_lines are not buffer text, so Vim's 'conceal' does not apply. Instead we
-- strip/normalise the markup here and emit styled chunks, so answers read like
-- rendered markdown: **bold**, *italic*, `code`, headings, lists, quotes and
-- fenced code blocks.
local util = require('threads.util')

local M = {}

-- Ordered by priority: earlier entries win when two patterns start at the same
-- position (e.g. `**strong**` before `*emph*`).
local INLINE = {
  { '%*%*(.-)%*%*', 'ThreadsMdStrong' },
  { '__(.-)__', 'ThreadsMdStrong' },
  { '`(.-)`', 'ThreadsMdCode' },
  { '%[(.-)%]%b()', 'ThreadsMdLink' },
  { '%*(.-)%*', 'ThreadsMdEmph' },
  { '_(.-)_', 'ThreadsMdEmph' },
  { '~~(.-)~~', 'ThreadsMdStrike' },
}

local function parse_inline(s)
  if s == '' then
    return {}
  end
  local out = {}
  local i = 1
  local n = #s
  while i <= n do
    local best_a, best_b, best_cap, best_hl
    for _, st in ipairs(INLINE) do
      local a, b, cap = s:find(st[1], i)
      if a and (not best_a or a < best_a) then
        best_a, best_b, best_cap, best_hl = a, b, cap, st[2]
      end
    end
    if not best_a then
      out[#out + 1] = { s:sub(i), 'ThreadsText' }
      break
    end
    if best_a > i then
      out[#out + 1] = { s:sub(i, best_a - 1), 'ThreadsText' }
    end
    if best_cap ~= '' then
      out[#out + 1] = { best_cap, best_hl }
    end
    i = best_b + 1
  end
  if #out == 0 then
    out[1] = { s, 'ThreadsText' }
  end
  return out
end

local function append_wrapped(out, text, width, hl, parse)
  local pieces = util.wrap(text, width)
  if #pieces == 0 then
    out[#out + 1] = {}
    return
  end
  for _, piece in ipairs(pieces) do
    if parse then
      out[#out + 1] = parse_inline(piece)
    else
      out[#out + 1] = { { piece, hl or 'ThreadsText' } }
    end
  end
end

--- Convert markdown text into a list of lines; each line is a list of
--- { text, hl_group } chunks.
function M.to_lines(content, width)
  width = math.max(width or 80, 8)
  local out = {}
  local in_fence = false
  for _, line in ipairs(vim.split(content or '', '\n', { plain = true })) do
    local fence = line:match('^%s*```') or line:match('^%s*~~~')
    if fence then
      in_fence = not in_fence
    elseif in_fence then
      append_wrapped(out, line, width, 'ThreadsMdCodeBlock', false)
    else
      local heading = line:match('^%s*#+%s+(.*)$')
      local quote = line:match('^%s*>%s?(.*)$')
      local bullet, bullet_text = line:match('^(%s*)[-*+]%s+(.*)$')
      if heading then
        append_wrapped(out, heading, width, 'ThreadsMdHeading', false)
      elseif quote then
        append_wrapped(out, '│ ' .. quote, width, nil, true)
      elseif bullet then
        append_wrapped(out, bullet .. '• ' .. bullet_text, width, nil, true)
      elseif line:match('^%s*[-*_][-*_][-*_]+%s*$') then
        out[#out + 1] = { { '────────────────', 'ThreadsMuted' } }
      else
        append_wrapped(out, line, width, nil, true)
      end
    end
  end
  if #out == 0 then
    out[1] = {}
  end
  return out
end

M._parse_inline = parse_inline

return M
