-- The filter prompt: one line under the tree that narrows the tree as it
-- is typed. It is deliberately outside the keymap, since while it is open
-- almost every key is literal text and enter, esc and backspace mean there
-- what they mean in any prompt.
local M = {}

local state = nil

--- Reports whether the prompt is open.
function M.is_open()
  return state ~= nil and vim.api.nvim_win_is_valid(state.win)
end

local function close()
  if not state then return end
  local win, buf = state.win, state.buf
  state = nil
  pcall(vim.api.nvim_win_close, win, true)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

-- Closing the prompt is itself a BufLeave, so accepting would otherwise be
-- followed by a cancel; whichever outcome comes first is the only one.
local function once(finished, fn)
  return function(...)
    if finished.done then return end
    finished.done = true
    fn(...)
  end
end

--- Opens the prompt over the bottom of parent.
--- @param opts table {parent=win, label=, initial=, on_change=, on_accept=, on_cancel=}
function M.open(opts)
  if M.is_open() then close() end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'prompt'
  vim.bo[buf].bufhidden = 'wipe'
  vim.fn.prompt_setprompt(buf, opts.label)
  local pos = vim.api.nvim_win_get_position(opts.parent)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = pos[1] + vim.api.nvim_win_get_height(opts.parent) - 1,
    col = pos[2],
    width = vim.api.nvim_win_get_width(opts.parent),
    height = 1,
    style = 'minimal',
    zindex = 60,
  })
  vim.wo[win].winhighlight = 'Normal:Normal'
  state = { win = win, buf = buf, label = opts.label }

  local function value()
    local text = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ''
    return text:sub(#opts.label + 1)
  end

  local finished = { done = false }
  vim.fn.prompt_setcallback(buf, once(finished, function()
    local v = value()
    close()
    if opts.on_accept then opts.on_accept(v) end
  end))
  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
    buffer = buf,
    callback = function()
      if opts.on_change then opts.on_change(value()) end
    end,
  })
  local cancel = once(finished, function()
    close()
    if opts.on_cancel then opts.on_cancel() end
  end)
  vim.keymap.set({ 'i', 'n' }, '<Esc>', cancel, { buffer = buf })
  vim.keymap.set('n', 'q', cancel, { buffer = buf })
  vim.api.nvim_create_autocmd('BufLeave', { buffer = buf, once = true, callback = cancel })

  if opts.initial and opts.initial ~= '' then
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { opts.label .. opts.initial })
  end
  vim.cmd('startinsert!')
  return win
end

M.close = close

return M
