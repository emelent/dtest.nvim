-- The two panes and the footer, in a tab page of their own. The log sits
-- on top, the tree below it, and the last two lines carry the summary, the
-- same arrangement the dtest TUI has. Motions inside a pane are Neovim's
-- own; everything else goes through an action, so a rebinding in the config
-- moves it without any handler knowing which key arrived.
local config = require('dtest.config')
local hl = require('dtest.ui.hl')
local prompt = require('dtest.ui.prompt')
local render = require('dtest.ui.render')
local session_mod = require('dtest.session')
local source = require('dtest.dotnet.source')
local trx = require('dtest.dotnet.trx')

local M = {}

-- The one open UI, or nil. dtest is a view of a solution, and two of them
-- fighting over the same dotnet processes would help nobody.
local S = nil

-- How often the spinner turns, and with it the redraw that shows the lines
-- a run has produced since the last frame. Output is not drawn as it
-- arrives: a burst of lines costs one rebuild rather than one each.
local frame_ms = 100

-- The summary is two lines and never more.
local footer_h = 2

-- Actions bound only in the tree, because the log pane wants those keys for
-- Neovim's own: n and N repeat a search, / starts one.
local tree_only = {
  ['expand'] = true, ['collapse'] = true, ['expand-all'] = true, ['collapse-all'] = true,
  ['toggle-fold'] = true, ['focus'] = true, ['unfocus'] = true, ['filter'] = true,
  ['only-failed'] = true, ['only-skipped'] = true, ['show-all'] = true,
  ['next-failure'] = true, ['previous-failure'] = true,
}

--- Reports whether the panes are open.
function M.is_open()
  return S ~= nil and vim.api.nvim_tabpage_is_valid(S.tab)
end

-- Drawing.

-- Writes lines (lists of {text, highlight} segments) into a buffer and
-- hangs the highlights off them.
local function set_lines(buf, lines)
  local texts = {}
  for i, l in ipairs(lines) do
    texts[i] = render.text(l)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, texts)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, hl.ns, 0, -1)
  for i, l in ipairs(lines) do
    local col = 0
    for _, seg in ipairs(l) do
      local len = #seg[1]
      if seg[2] and len > 0 then
        pcall(vim.api.nvim_buf_set_extmark, buf, hl.ns, i - 1, col, {
          end_col = col + len,
          hl_group = seg[2],
        })
      end
      col = col + len
    end
  end
end

-- A fingerprint of what a pane would draw, so an unchanged pane is left
-- alone and the cursor and the view with it.
local function signature(lines)
  local parts = {}
  for i, l in ipairs(lines) do
    parts[i] = render.text(l)
  end
  return table.concat(parts, '\n')
end

--- The tree node under the cursor.
function M.current()
  if not M.is_open() or not vim.api.nvim_win_is_valid(S.wins.tree) then return nil end
  local row = vim.api.nvim_win_get_cursor(S.wins.tree)[1]
  return S.rows[row]
end

local function spinner_frame()
  local frames = config.options.icons.spinner
  return frames[(S.tick % #frames) + 1]
end

local function draw_tree()
  local ctx = { spinner = spinner_frame(), filtered = S.session:filtered() }
  -- A node the last action asked for wins over where the cursor happens to
  -- be, since moving the cursor is exactly what it is asking for.
  local keep = S.pending or M.current() or S.selected
  S.pending = nil
  local lines, rows = render.tree_lines(S.session, ctx)
  local sig = signature(lines)
  if sig ~= S.tree_sig then
    S.tree_sig = sig
    set_lines(S.bufs.tree, lines)
  end
  S.rows = rows
  -- Keep the cursor on its node or, when a fold hid it, its nearest
  -- visible ancestor.
  local target = 1
  local node = keep
  while node do
    local found
    for i, r in ipairs(rows) do
      if r == node then
        found = i
        break
      end
    end
    if found then
      target = found
      break
    end
    node = node.parent
  end
  target = math.min(target, math.max(1, #rows))
  S.guard = true
  pcall(vim.api.nvim_win_set_cursor, S.wins.tree, { target, 0 })
  S.guard = false
  S.selected = rows[target]
end

local function draw_log()
  local node = S.selected
  local lines
  if S.help then
    lines = render.help_lines()
  else
    lines = render.log_lines(S.session, node)
  end
  local sig = signature(lines)
  local changed_node = node ~= S.log_node or S.help ~= S.log_help
  if sig == S.log_sig and not changed_node then return end
  local win = S.wins.log
  local at_bottom = false
  if vim.api.nvim_win_is_valid(win) then
    local cursor = vim.api.nvim_win_get_cursor(win)[1]
    at_bottom = cursor >= vim.api.nvim_buf_line_count(S.bufs.log)
  end
  S.log_sig, S.log_node, S.log_help = sig, node, S.help
  set_lines(S.bufs.log, lines)
  if not vim.api.nvim_win_is_valid(win) then return end
  if changed_node then
    pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
  elseif S.session.show_output and at_bottom then
    -- Raw output is a tail: while it is being followed, keep following it.
    pcall(vim.api.nvim_win_set_cursor, win, { #lines, 0 })
  end
end

local function draw_footer()
  if not S.wins.footer or not vim.api.nvim_win_is_valid(S.wins.footer) then return end
  set_lines(S.bufs.footer, render.footer_lines(S.session))
end

local function log_title()
  local node = S.selected
  if S.help then return 'Usage' end
  if S.session.show_output then
    local _, name = S.session:output_for(node)
    return 'Output  ' .. name
  end
  if not node then return 'Log' end
  return 'Log  ' .. node:breadcrumb()
end

local function tree_title()
  local s = S.session
  local title = 'Tests'
  if s.zoom then title = title .. '  in ' .. s.zoom:breadcrumb() end
  if s.status_filter == 'failed' then
    title = title .. '  failed only'
  elseif s.status_filter == 'skipped' then
    title = title .. '  skipped only'
  end
  if s.query ~= '' then title = title .. '  filter: ' .. s.query end
  return title
end

local function draw_titles()
  local focused = vim.api.nvim_get_current_win()
  for _, pane in ipairs({ 'log', 'tree' }) do
    local win = S.wins[pane]
    if vim.api.nvim_win_is_valid(win) then
      local has_focus = win == focused
      local title = pane == 'log' and log_title() or tree_title()
      vim.wo[win].winbar = render.pane_title(title, has_focus, vim.api.nvim_win_get_width(win))
      -- Both cursor lines stay lit, since the tree's is what the log is
      -- showing; the one without focus is simply drawn a shade back.
      vim.wo[win].winhighlight = 'CursorLine:' ..
        (has_focus and 'DtestCursorLine' or 'DtestCursorLineNC')
    end
  end
end

--- Redraws everything that has changed.
function M.render()
  if not M.is_open() then return end
  draw_tree()
  draw_log()
  draw_footer()
  draw_titles()
end

-- Coalesces the many small changes a run produces into one redraw.
local function schedule_render()
  if not S or S.pending_render then return end
  S.pending_render = true
  vim.schedule(function()
    if not S then return end
    S.pending_render = false
    M.render()
  end)
end

-- The clock behind the spinner and the elapsed time in the footer. It only
-- runs while dotnet is busy, so an idle dtest costs nothing.
local function tick()
  if not S then return end
  S.tick = S.tick + 1
  if S.session:busy() then
    M.render()
  end
end

-- Opening and closing.

-- The buffer names double as the tab's label, so they are short and read
-- as words rather than as paths.
local buffer_names = { tree = 'dtest', log = 'dtest-log', footer = 'dtest-summary' }

M.buffer_names = buffer_names

local function make_buffer(name, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, buffer_names[name])
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = filetype
  return buf
end

local function setup_window(win, opts)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].foldcolumn = '0'
  vim.wo[win].list = false
  vim.wo[win].spell = false
  vim.wo[win].wrap = opts.wrap
  vim.wo[win].cursorline = opts.cursorline
  vim.wo[win].winfixheight = true
  -- No ~ past the end: these panes are reports, not files being edited.
  vim.wo[win].fillchars = 'eob: '
  vim.wo[win].statusline = ' '
end

--- Closes the panes and stops whatever dotnet is doing.
function M.close()
  if not S then return end
  local state = S
  S = nil
  prompt.close()
  if state.timer then
    state.timer:stop()
    state.timer:close()
  end
  state.session:shutdown()
  if state.saved then
    vim.o.laststatus = state.saved.laststatus
    vim.o.ruler = state.saved.ruler
  end
  pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  -- Closing every window of the only tab page would close the editor, so
  -- an empty one is put in its place first.
  if vim.api.nvim_tabpage_is_valid(state.tab) and #vim.api.nvim_list_tabpages() == 1 then
    vim.cmd('tabnew')
  end
  for _, win in pairs(state.wins) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, buf in pairs(state.bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  if vim.api.nvim_tabpage_is_valid(state.tab) and #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.api.nvim_win_close, vim.api.nvim_tabpage_list_wins(state.tab)[1], true)
  end
  if state.origin and vim.api.nvim_win_is_valid(state.origin) then
    pcall(vim.api.nvim_set_current_win, state.origin)
  end
end

--- Opens the panes for target, or brings the open ones forward.
function M.open(target)
  if M.is_open() then
    vim.api.nvim_set_current_tabpage(S.tab)
    return
  end
  local opts = config.options
  target = target or opts.target or vim.uv.cwd()
  target = vim.fn.fnamemodify(vim.fs.normalize(target), ':p'):gsub('/$', '')
  local stat = vim.uv.fs_stat(target)
  if not stat then
    vim.notify('dtest: ' .. target .. ': no such file', vim.log.levels.ERROR)
    return
  end
  -- A directory (or nothing at all) means: whatever is in there.
  if stat.type == 'directory' then
    local found, err = require('dtest.dotnet.solution').find_target(target)
    if not found then
      vim.notify('dtest: ' .. err, vim.log.levels.ERROR)
      return
    end
    target = found
  end

  hl.setup()
  local origin = vim.api.nvim_get_current_win()
  vim.cmd('tabnew')
  local tab = vim.api.nvim_get_current_tabpage()
  local log_win = vim.api.nvim_get_current_win()
  local placeholder = vim.api.nvim_win_get_buf(log_win)

  local bufs = {
    log = make_buffer('log', 'dtest-log'),
    tree = make_buffer('tree', 'dtest-tree'),
    footer = opts.layout.footer and make_buffer('footer', 'dtest-summary') or nil,
  }
  vim.api.nvim_win_set_buf(log_win, bufs.log)
  vim.cmd('belowright split')
  local tree_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(tree_win, bufs.tree)
  local footer_win
  if opts.layout.footer then
    vim.cmd('belowright split')
    footer_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(footer_win, bufs.footer)
  end
  if vim.api.nvim_buf_is_valid(placeholder) and placeholder ~= bufs.log then
    pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
  end

  setup_window(log_win, { wrap = true, cursorline = true })
  setup_window(tree_win, { wrap = false, cursorline = true })
  if footer_win then
    setup_window(footer_win, { wrap = false, cursorline = false })
    vim.wo[footer_win].winbar = ''
    vim.api.nvim_win_set_height(footer_win, footer_h)
  end

  local session = session_mod.new(target, {
    configuration = opts.configuration,
    no_build = opts.no_build,
  })
  S = {
    tab = tab,
    origin = origin,
    wins = { log = log_win, tree = tree_win, footer = footer_win },
    bufs = bufs,
    session = session,
    rows = {},
    selected = nil,
    tick = 0,
    pending = nil, -- a node the next redraw should put the cursor on
    help = false,
    guard = false,
    augroup = vim.api.nvim_create_augroup('dtest', { clear = true }),
  }
  session.on_change = schedule_render
  -- A run started from a source buffer leaves the summary out of sight, so
  -- how it went is said out loud instead.
  session.on_batch_end = function(counts)
    if not M.is_open() or vim.api.nvim_get_current_tabpage() == S.tab then return end
    vim.notify(string.format('dtest: %s — %d failed | %d passed | %d skipped',
      session.name, counts.failed, counts.passed, counts.skipped),
      counts.failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
  end

  S.saved = { laststatus = vim.o.laststatus, ruler = vim.o.ruler }
  vim.o.laststatus = 0 -- the pane titles say which pane is which
  vim.o.ruler = false   -- and a line number means nothing in a report
  M.resize()
  M.bind_keys()
  M.bind_autocmds()

  S.timer = vim.uv.new_timer()
  S.timer:start(frame_ms, frame_ms, vim.schedule_wrap(tick))

  vim.api.nvim_set_current_win(tree_win)
  M.render()
  session:start()
end

--- Opens the panes if they are closed. Focus stays where it is unless
--- opts.focus asks otherwise, so a run started from a source buffer leaves
--- the cursor in the code it came from.
--- @return table|nil session
function M.ensure_open(opts)
  opts = opts or {}
  if not M.is_open() then
    local back = vim.api.nvim_get_current_win()
    M.open(opts.target)
    if not M.is_open() then return nil end
    if not opts.focus and vim.api.nvim_win_is_valid(back) then
      pcall(vim.api.nvim_set_current_win, back)
    end
  elseif opts.focus then
    vim.api.nvim_set_current_tabpage(S.tab)
  end
  return S.session
end

--- Puts the tree cursor on a node, opening whatever hides it.
function M.reveal(node)
  if not M.is_open() or not node then return end
  local parent = node.parent
  while parent do
    parent.expanded = true
    parent = parent.parent
  end
  S.pending = node
  M.render()
end

--- Says something in the summary line, and out loud as well when the panes
--- are not the tab being looked at.
function M.announce(text, is_error)
  if S then S.session:notify(text, is_error) end
  if not M.is_open() or vim.api.nvim_get_current_tabpage() ~= S.tab then
    vim.notify('dtest: ' .. text, is_error and vim.log.levels.WARN or vim.log.levels.INFO)
  end
end

--- Opens the panes when they are closed and closes them when they are open.
function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

--- Gives the log pane its share of the height and the tree the rest.
function M.resize()
  if not M.is_open() then return end
  local total = vim.api.nvim_win_get_height(S.wins.log)
    + vim.api.nvim_win_get_height(S.wins.tree)
    + (S.wins.footer and vim.api.nvim_win_get_height(S.wins.footer) or 0)
  local body = math.max(4, total - (S.wins.footer and footer_h or 0))
  pcall(vim.api.nvim_win_set_height, S.wins.log,
    math.max(3, math.floor(body * config.options.layout.log_ratio)))
  if S.wins.footer then
    pcall(vim.api.nvim_win_set_height, S.wins.footer, footer_h)
  end
end

-- Actions.

local actions = {}
M.actions = actions

local function selected()
  return M.current()
end

function actions.quit()
  M.close()
end

actions['switch-pane'] = function()
  local win = vim.api.nvim_get_current_win()
  local next_win = win == S.wins.log and S.wins.tree or S.wins.log
  vim.api.nvim_set_current_win(next_win)
  M.render()
end

function actions.expand()
  local n = selected()
  if n and not n:is_leaf() and not S.session:filtered() then
    n.expanded = true
    M.render()
  end
end

function actions.collapse()
  local n = selected()
  if not n then return end
  if not n:is_leaf() and n.expanded and not S.session:filtered() then
    n.expanded = false
  elseif n.parent then
    S.pending = n.parent -- h on a closed node steps out to its parent
  end
  M.render()
end

actions['toggle-fold'] = function()
  local n = selected()
  if n and not n:is_leaf() and not S.session:filtered() then
    n.expanded = not n.expanded
    M.render()
  end
end

actions['expand-all'] = function()
  S.session.tree:set_expanded(true)
  M.render()
end

actions['collapse-all'] = function()
  S.session.tree:set_expanded(false)
  M.render()
end

function actions.focus()
  local n = selected()
  if not n then return end
  if n:is_leaf() then
    S.session:notify('Nothing to focus on under ' .. n.name, true)
    return
  end
  if n == S.session.zoom then
    S.session:notify('Already focused on ' .. n.name, false)
    return
  end
  S.session.zoom = n
  n.expanded = true
  S.pending = n
  M.render()
end

function actions.unfocus()
  local s = S.session
  if not s.zoom then
    s:notify('Not focused on anything', false)
    return
  end
  local was = s.zoom
  s.zoom = was.parent ~= s.tree.root and was.parent or nil
  S.pending = was
  M.render()
end

function actions.run()
  local n = selected()
  if n then S.session:enqueue({ n }) end
end

actions['run-all'] = function()
  S.session:enqueue({ S.session:root() })
end

actions['run-failed'] = function()
  S.session:run_failed()
end

function actions.cancel()
  S.session:cancel()
end

actions['only-failed'] = function()
  local s = S.session
  s.status_filter = s.status_filter ~= 'failed' and 'failed' or nil
  M.render()
end

actions['only-skipped'] = function()
  local s = S.session
  s.status_filter = s.status_filter ~= 'skipped' and 'skipped' or nil
  M.render()
end

actions['show-all'] = function()
  S.session.query, S.session.status_filter = '', nil
  M.render()
end

function actions.clear()
  if S.help then
    S.help = false
  else
    S.session.query, S.session.status_filter = '', nil
  end
  M.render()
end

actions['toggle-output'] = function()
  S.session.show_output = not S.session.show_output
  S.log_node = nil -- a different kind of content, so start at the top
  M.render()
end

function actions.reload()
  S.session:reload()
end

function actions.help()
  S.help = not S.help
  M.render()
  if S.help then
    -- "press any key to close": the next key press puts the log back, and
    -- is swallowed rather than acted on, so leaving the help cannot run
    -- something by accident.
    local ns = vim.api.nvim_create_namespace('dtest.help')
    vim.on_key(function()
      vim.on_key(nil, ns)
      vim.schedule(function()
        if S then
          S.help = false
          M.render()
        end
      end)
      return ''
    end, ns)
  end
end

actions['next-failure'] = function()
  local n = S.session:next_failure(selected(), true)
  if not n then
    S.session:notify('No failed tests', false)
    return
  end
  M.reveal(n)
end

actions['previous-failure'] = function()
  local n = S.session:next_failure(selected(), false)
  if not n then
    S.session:notify('No failed tests', false)
    return
  end
  M.reveal(n)
end

function actions.filter()
  local s = S.session
  local before = s.query
  prompt.open({
    parent = S.wins.tree,
    label = '? Filter › ',
    initial = s.query,
    on_change = function(v)
      s.query = v
      M.render()
    end,
    on_accept = function(v)
      s.query = v
      M.render()
    end,
    on_cancel = function()
      -- esc out of the prompt clears every filter, the way esc does in the
      -- tree; keeping a filter is what enter is for.
      s.query, s.status_filter = '', nil
      M.render()
    end,
  })
end

--- Opens a source position in the window dtest was opened from.
local function open_location(loc)
  local win = S.origin
  if not win or not vim.api.nvim_win_is_valid(win) then
    vim.cmd('tabedit ' .. vim.fn.fnameescape(loc.file))
  else
    vim.api.nvim_set_current_win(win)
    vim.cmd('edit ' .. vim.fn.fnameescape(loc.file))
  end
  if loc.line and loc.line > 0 then
    pcall(vim.api.nvim_win_set_cursor, 0, { loc.line, 0 })
    vim.cmd('normal! zz')
  end
end

actions['open-in-editor'] = function()
  local n = selected()
  if not n then return end
  local loc
  if vim.api.nvim_get_current_win() == S.wins.log then
    loc = source.location_in_line(vim.api.nvim_get_current_line())
  end
  if not loc and n:status() == 'failed' and n.result then
    loc = trx.failure_location(n.result)
  end
  if not loc then
    loc = S.session:locate(n)
  end
  if not loc then
    S.session:notify('No source location for ' .. n.name, true)
    return
  end
  open_location(loc)
end

-- Keys and autocommands.

function M.bind_keys()
  for action, fn in pairs(actions) do
    for _, key in ipairs(config.bindings(action)) do
      local targets = tree_only[action] and { 'tree' } or { 'tree', 'log' }
      for _, pane in ipairs(targets) do
        vim.keymap.set('n', key, function()
          if not M.is_open() then return end
          fn()
        end, { buffer = S.bufs[pane], nowait = true, silent = true, desc = 'dtest ' .. action })
      end
    end
  end
end

function M.bind_autocmds()
  local group = S.augroup
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = group,
    buffer = S.bufs.tree,
    callback = function()
      if not M.is_open() or S.guard then return end
      local node = M.current()
      if node ~= S.selected then
        S.selected = node
        draw_log()
        draw_titles()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'WinEnter', 'BufEnter' }, {
    group = group,
    callback = function()
      if M.is_open() then draw_titles() end
    end,
  })
  -- The status lines are hidden while dtest is on screen and come back the
  -- moment another tab is, so nothing else loses its bottom line.
  vim.api.nvim_create_autocmd('TabEnter', {
    group = group,
    callback = function()
      if not M.is_open() then return end
      if vim.api.nvim_get_current_tabpage() == S.tab then
        vim.o.laststatus, vim.o.ruler = 0, false
      else
        vim.o.laststatus, vim.o.ruler = S.saved.laststatus, S.saved.ruler
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'VimResized', 'WinResized' }, {
    group = group,
    callback = function()
      if not M.is_open() then return end
      M.resize()
      M.render()
    end,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(args)
      if not M.is_open() then return end
      local closed = tonumber(args.match)
      for _, win in pairs(S.wins) do
        if win == closed then
          vim.schedule(M.close)
          return
        end
      end
    end,
  })
end

--- The session behind the open panes, for the public API and the tests.
function M.session()
  return S and S.session or nil
end

return M
