-- threads.nvim: small helpers shared by all modules
local M = {}

--- Absolute path of a normal file buffer, or nil for special buffers.
function M.buf_path(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local btype = vim.bo[bufnr].buftype
  if btype ~= '' and btype ~= 'acwrite' then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' then
    return nil
  end
  if vim.fn.isdirectory(name) == 1 then
    return nil
  end
  local path = vim.fn.fnamemodify(name, ':p')
  if path:sub(-1) == '/' then
    return nil
  end
  return path
end

function M.sha(s)
  return vim.fn.sha256(s)
end

--- Unique-enough thread id.
function M.id()
  return 't_' .. vim.fn.sha256(tostring(vim.uv.hrtime()) .. tostring(math.random(1e9))):sub(1, 12)
end

function M.notify(msg, level)
  vim.notify('threads.nvim: ' .. tostring(msg), level or vim.log.levels.INFO)
end

--- Clamp a 0-indexed, end-col-exclusive range to the buffer contents.
function M.clamp_range(bufnr, range)
  range = range or {}
  local n = vim.api.nvim_buf_line_count(bufnr)
  if n < 1 then
    n = 1
  end
  local start_row = math.max(math.min(tonumber(range.start_row) or 0, n - 1), 0)
  local end_row = math.max(math.min(tonumber(range.end_row) or start_row, n - 1), start_row)
  local start_line = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, false)[1] or ''
  local end_line = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1] or ''
  local start_col = math.max(math.min(tonumber(range.start_col) or 0, #start_line), 0)
  local end_col = tonumber(range.end_col) or #end_line
  if end_row == start_row then
    end_col = math.max(math.min(end_col, #end_line), start_col)
  else
    end_col = math.max(math.min(end_col, #end_line), 0)
  end
  return {
    start_row = start_row,
    start_col = start_col,
    end_row = end_row,
    end_col = end_col,
  }
end

--- Lines covered by a range, with first/last line partially included.
function M.text_in_range(bufnr, range)
  local r = M.clamp_range(bufnr, range)
  local lines = vim.api.nvim_buf_get_lines(bufnr, r.start_row, r.end_row + 1, false)
  if #lines == 0 then
    return {}
  end
  if r.start_row == r.end_row then
    lines[1] = lines[1]:sub(r.start_col + 1, r.end_col)
  else
    lines[1] = lines[1]:sub(r.start_col + 1)
    lines[#lines] = lines[#lines]:sub(1, r.end_col)
  end
  return lines
end

function M.same_lines(a, b)
  if type(a) ~= 'table' or type(b) ~= 'table' or #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

function M.same_range(a, b)
  if not a or not b then
    return false
  end
  return a.start_row == b.start_row
    and a.start_col == b.start_col
    and a.end_row == b.end_row
    and a.end_col == b.end_col
end

function M.deepcopy(t)
  return vim.deepcopy(t)
end

--- Wrap text to `width` display cells, honouring paragraphs and spaces.
function M.wrap(text, width)
  width = math.max(tonumber(width) or 80, 8)
  local out = {}
  for _, para in ipairs(vim.split(text or '', '\n', { plain = true })) do
    if para == '' then
      out[#out + 1] = ''
    else
      local current = ''
      local curw = 0
      local n = vim.fn.strchars(para)
      for i = 0, n - 1 do
        local ch = vim.fn.strcharpart(para, i, 1)
        local cw = vim.fn.strdisplaywidth(ch)
        if curw + cw > width and current ~= '' then
          local cut = current:find(' +%S*$')
          if cut and cut > 1 then
            local rest = current:sub(cut + 1)
            out[#out + 1] = current:sub(1, cut - 1)
            current = rest:gsub('^%s+', '')
            if current == '' then
              current = rest
            end
            curw = vim.fn.strdisplaywidth(current)
          else
            out[#out + 1] = current
            current = ''
            curw = 0
          end
        end
        current = current .. ch
        curw = curw + cw
      end
      if current ~= '' then
        out[#out + 1] = current
      end
    end
  end
  return out
end

--- Single-line preview of a possibly multiline string.
function M.preview(text, max)
  max = max or 60
  if not text then
    return ''
  end
  local one = text:gsub('%s+', ' ')
  one = one:gsub('^%s+', ''):gsub('%s+$', '')
  if vim.fn.strchars(one) > max then
    return vim.fn.strcharpart(one, 0, max - 1) .. '…'
  end
  return one
end

function M.time_ago(ts)
  if not ts or ts == 0 then
    return ''
  end
  local d = os.time() - ts
  if d < 60 then
    return d .. 's ago'
  elseif d < 3600 then
    return math.floor(d / 60) .. 'm ago'
  elseif d < 86400 then
    return math.floor(d / 3600) .. 'h ago'
  end
  return math.floor(d / 86400) .. 'd ago'
end

function M.file_label(path)
  if not path then
    return ''
  end
  local home = vim.fn.expand('~')
  if home ~= '' and path:sub(1, #home) == home then
    return '~' .. path:sub(#home + 1)
  end
  return path
end

function M.list_contains(list, value)
  for _, v in ipairs(list or {}) do
    if v == value then
      return true
    end
  end
  return false
end

return M
