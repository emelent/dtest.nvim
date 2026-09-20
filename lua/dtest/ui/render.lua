-- Turning the session into lines. Every function here returns a list of
-- lines, and every line is a list of {text, highlight} segments, so the
-- caller can write the text into a buffer and hang the highlights off it
-- without either having to know about the other.
local config = require('dtest.config')
local session_mod = require('dtest.session')
local trx = require('dtest.dotnet.trx')
local util = require('dtest.util')

local M = {}

-- vitest's slowTestThreshold: anything that took longer is worth a second
-- look, so its time is drawn in the warning colour.
local SLOW = 0.3

-- Tree guides, drawn down the left of the tree so the nesting reads at a
-- glance. Each level below the project costs one three-column step.
local GUIDE = { branch = '├─ ', last = '└─ ', bar = '│  ', gap = '   ' }

--- A line under construction; segments are appended in drawing order.
local function line(...)
  local l = {}
  for _, seg in ipairs({ ... }) do l[#l + 1] = seg end
  return l
end

local function add(l, text, hl)
  if text ~= nil and text ~= '' then l[#l + 1] = { text, hl } end
  return l
end

M.line, M.add = line, add

--- The plain text of a rendered line.
function M.text(l)
  local parts = {}
  for _, seg in ipairs(l) do parts[#parts + 1] = seg[1] end
  return table.concat(parts)
end

-- Durations.

--- A duration as two segments: the number in the colour of how slow it is,
--- and the unit a faded shade of that same colour, so the number reads
--- first. Compound forms (2m34s) carry a unit inside the number, so they
--- are left in one shade.
local function duration_segments(l, seconds, in_tree)
  local slow = seconds > SLOW
  local prefix = in_tree and 'DtestTree' or 'Dtest'
  local hl = prefix .. (slow and 'Slow' or 'Quick')
  local unit_hl = hl .. 'Unit'
  local s = util.duration(seconds)
  local number, unit = s:match('^([%d%.]+)(%a+)$')
  if number then
    add(l, number, hl)
    add(l, unit, unit_hl)
  else
    add(l, s, hl)
  end
  return l
end

M.duration_segments = duration_segments

-- The tree.

local function icons()
  return config.options.icons
end

local function status_icon(status)
  local i = icons()
  if status == 'passed' then return i.passed end
  if status == 'failed' then return i.failed end
  if status == 'skipped' then return i.skipped end
  if status == 'queued' then return i.queued end
  return i.none
end

M.status_icon = status_icon

-- The highlight a status wears, in the tree or outside it.
local function status_hl(status, in_tree)
  local prefix = in_tree and 'DtestTree' or 'Dtest'
  if status == 'passed' then return prefix .. 'Passed' end
  if status == 'failed' then return prefix .. 'Failed' end
  if status == 'skipped' then return prefix .. 'Skipped' end
  if status == 'running' then return prefix .. 'Running' end
  if status == 'queued' then return 'DtestQueued' end
  return 'DtestDim'
end

M.status_hl = status_hl

--- The branch lines down the left of the tree, one per row: a corner or a
--- tee at the row's own level, and above it a bar for every level that
--- carries on further down. It works off the visible rows, so a filtered
--- tree still joins up.
function M.guides(rows)
  -- Depths are measured from the row the view is rooted at, which is the
  -- first one, so a focused subtree is drawn flush rather than carrying the
  -- indentation of where it sits in the whole tree.
  local base = rows[1] and rows[1]:depth() or 0
  local depth, deepest = {}, 0
  for i, n in ipairs(rows) do
    depth[i] = n:depth() - base
    deepest = math.max(deepest, depth[i])
  end
  -- Backwards: a row is the last of its siblings unless a row at the same
  -- depth was already seen without dropping shallower in between.
  local last, more = {}, {}
  for i = #rows, 1, -1 do
    local d = depth[i]
    last[i] = not more[d]
    more[d] = true
    for k = d + 1, deepest + 1 do more[k] = false end
  end
  -- Forwards: every ancestor has been seen by the time its children are, so
  -- carries[k] says whether this row's ancestor at depth k has siblings
  -- still to come.
  local out, carries = {}, {}
  for i, d in ipairs(depth) do
    carries[d] = not last[i]
    local parts = {}
    for k = 1, d - 1 do
      parts[#parts + 1] = carries[k] and GUIDE.bar or GUIDE.gap
    end
    if d > 0 then
      parts[#parts + 1] = last[i] and GUIDE.last or GUIDE.branch
    end
    out[i] = table.concat(parts)
  end
  return out
end

-- The fold glyph for a group: open when expanded or filtered.
local function arrow(node, filtered)
  return (node.expanded or filtered) and icons().open or icons().closed
end

--- A node's glyph in the tree: a fold arrow for the root, a project, a
--- class or a theory, a status glyph for a test, each in the colour of its
--- status. While tests run only the running project spins; everything
--- running beneath it is simply drawn in the running colour, so the tree
--- does not flicker all over.
local function tree_icon(l, node, ctx)
  local status = node:status()
  if status == 'running' then
    if node.kind == 'project' then
      return add(l, ctx.spinner, 'DtestRunning')
    end
    return add(l, node:is_leaf() and icons().none or arrow(node, ctx.filtered), 'DtestTreeRunning')
  end
  local glyph = node:is_leaf() and status_icon(status) or arrow(node, ctx.filtered)
  return add(l, glyph, status_hl(status, true))
end

-- "4 tests", or "1 test".
local function test_count(n)
  return util.plural(n, 'test')
end

--- vitest's "(4 tests | 1 failed | 1 skipped)". How many there are is grey,
--- being a fact about the tree rather than a result, and the outcomes are a
--- shade back from the footer's, which is the line meant to be read at a
--- glance.
local function counts_segments(l, c)
  add(l, '(', 'DtestDim')
  local first = true
  local function part(text, hl)
    if not first then add(l, ' | ', 'DtestDim') end
    first = false
    add(l, text, hl)
  end
  part(test_count(c.total), 'DtestDim')
  if c.running > 0 then part(c.running .. ' running', 'DtestTreeRunning') end
  if c.queued > 0 then part(c.queued .. ' queued', 'DtestQueued') end
  if c.failed > 0 then part(c.failed .. ' failed', 'DtestTreeFailed') end
  if c.skipped > 0 then part(c.skipped .. ' skipped', 'DtestTreeSkipped') end
  add(l, ')', 'DtestDim')
  return l
end

-- The root and the projects are the tree's headings, drawn in bold rather
-- than in a status colour.
local function is_heading(node)
  return node.kind == 'root' or node.kind == 'project'
end

--- One tree row: the branch guide, the glyph, the name and, for groups, the
--- counts, then the duration. The root is the exception: it names how many
--- tests the solution has and stops there, since how the last run went is
--- what the footer is for.
function M.node_line(node, guide, ctx)
  local l = line()
  add(l, '  ')
  add(l, guide, 'DtestDim')
  tree_icon(l, node, ctx)
  add(l, ' ')
  local status = node:status()
  if status == 'failed' and node:is_leaf() then
    add(l, node.name, 'DtestTreeFailed')
  elseif status == 'skipped' and node:is_leaf() then
    add(l, node.name, 'DtestDim')
    add(l, ' [skipped]', 'DtestTreeSkipped')
  elseif status == 'queued' then
    -- Everything waiting for its run is greyed out, name included; the root
    -- and the projects keep their weight so the tree still has headings.
    add(l, node.name, is_heading(node) and 'DtestBold' or 'DtestQueued')
  elseif is_heading(node) then
    add(l, node.name, 'DtestBold')
  else
    add(l, node.name)
  end
  if node.kind == 'root' then
    add(l, ' ')
    add(l, '(' .. util.plural(#node.children, 'project') .. ' | ' .. test_count(node:counts().total) .. ')', 'DtestDim')
  elseif not node:is_leaf() then
    add(l, ' ')
    counts_segments(l, node:counts())
  end
  local d = node:duration()
  if node.kind ~= 'root' and (d > 0 or (node:is_leaf() and node.result and status ~= 'skipped')) then
    add(l, ' ')
    duration_segments(l, d, true)
  end
  return l
end

--- Every row of the tree pane, with the nodes they were drawn from.
function M.tree_lines(session, ctx)
  local rows = session:rows()
  local lines = {}
  if #rows == 0 then
    lines[1] = M.empty_tree_line(session, ctx)
    return lines, rows
  end
  local guides = M.guides(rows)
  for i, node in ipairs(rows) do
    lines[i] = M.node_line(node, guides[i], ctx)
  end
  return lines, rows
end

function M.empty_tree_line(session, ctx)
  local l = line()
  if session.building then
    add(l, '  ' .. ctx.spinner .. ' ', 'DtestRunning')
    add(l, 'Building ' .. vim.fs.basename(session.target) .. '…', 'DtestDim')
  elseif session.loading > 0 then
    add(l, '  ' .. ctx.spinner .. ' ', 'DtestRunning')
    add(l, 'Listing tests…', 'DtestDim')
  elseif session.query ~= '' then
    add(l, '  No tests match ' .. session.query, 'DtestDim')
  elseif session.status_filter == 'failed' then
    add(l, '  No failed tests', 'DtestDim')
  elseif session.status_filter == 'skipped' then
    add(l, '  No skipped tests', 'DtestDim')
  else
    add(l, '  No tests found', 'DtestDim')
  end
  return l
end

-- The log.

-- Highlights one line of a failure message: the two sides of a failed
-- comparison, the expected value green and the actual value red. It
-- understands xUnit and NUnit ("Expected: …" then "Actual: …" or "But was:
-- …" on their own lines) and MSTest ("Expected:<…>. Actual:<…>." on one).
local function assertion_line(text)
  local indent, trimmed = text:match('^(%s*)(.*)$')
  if trimmed:sub(1, 8) == 'Expected' then
    local i = trimmed:find('Actual', 2, true)
    local l = line()
    add(l, indent)
    if i then
      add(l, trimmed:sub(1, i - 1), 'DtestExpected')
      add(l, trimmed:sub(i), 'DtestActual')
    else
      add(l, trimmed, 'DtestExpected')
    end
    return l
  end
  if trimmed:sub(1, 6) == 'Actual' or trimmed:sub(1, 7) == 'But was' then
    return line({ indent, nil }, { trimmed, 'DtestActual' })
  end
  return nil
end

-- Classifies a raw dotnet line; the first rule that matches styles it.
local log_rules = {
  { function(s) return s:sub(1, 2) == '$ ' end, 'DtestCommand' },
  { function(s) return vim.trim(s):sub(1, 7) == 'Passed ' end, 'DtestPassed' },
  { function(s) return vim.trim(s):sub(1, 7) == 'Failed ' end, 'DtestFailed' },
  { function(s) return vim.trim(s):sub(1, 8) == 'Skipped ' end, 'DtestSkipped' },
  { function(s) return s:sub(1, 10) == '[xUnit.net' end, 'DtestDim' },
  { function(s) return vim.trim(s):sub(1, 3) == 'at ' end, 'DtestDim' },
  { function(s)
    return s:find('error ', 1, true) or s:find('Error Message', 1, true)
      or s:find('Test Run Failed', 1, true) or s:find('Build FAILED', 1, true)
      or s:find('[FAIL]', 1, true) or vim.trim(s):sub(1, 7) == 'Failed:'
      or s:find('Exception', 1, true) or s:find('Assert.', 1, true) or s:find('Failure', 1, true)
  end, 'DtestError' },
  { function(s)
    return s:find('warning ', 1, true) or s:find('[SKIP]', 1, true) or vim.trim(s):sub(1, 8) == 'Skipped:'
  end, 'DtestSkipped' },
  { function(s)
    return s:find('Test Run Successful', 1, true) or s:find('Build succeeded', 1, true)
      or vim.trim(s):sub(1, 7) == 'Passed:'
  end, 'DtestPassed' },
}

--- Styles one line of raw dotnet output for reading.
function M.output_line(text)
  local assertion = assertion_line(text)
  if assertion then return assertion end
  for _, rule in ipairs(log_rules) do
    if rule[1](text) then return line({ text, rule[2] }) end
  end
  return line({ text })
end

local function message_line(text)
  return assertion_line(text) or line({ text, 'DtestError' })
end

local function output_section(lines, output)
  if output == '' then return end
  lines[#lines + 1] = line()
  lines[#lines + 1] = line({ '  Output', 'DtestDim' })
  for text in (output .. '\n'):gmatch('([^\n]*)\n') do
    lines[#lines + 1] = line({ text })
  end
end

-- Keeps the error lines of a build log.
local function build_errors(log)
  local out = {}
  for _, l in ipairs(log or {}) do
    if l:find(': error ', 1, true) or l:find('Build FAILED', 1, true) or l:sub(1, 18) == 'dotnet build failed' then
      out[#out + 1] = l
    end
  end
  return out
end

--- One failed test: the FAIL badge and breadcrumb, the message with its
--- assertion coloured, the failing location and, in full, the stack trace
--- and captured output.
local function failure_lines(lines, node, full)
  local r = node.result
  local head = line()
  add(head, '  ')
  add(head, ' FAIL ', 'DtestBadgeFail')
  add(head, ' ')
  add(head, node:breadcrumb(), 'DtestBold')
  add(head, ' ')
  duration_segments(head, r.duration, false)
  lines[#lines + 1] = head
  for text in ((r.message or ''):gsub('\n+$', '') .. '\n'):gmatch('([^\n]*)\n') do
    lines[#lines + 1] = message_line(text)
  end
  local loc = trx.failure_location(r)
  if loc then
    lines[#lines + 1] = line({ ' ' .. config.options.icons.arrow .. ' '
      .. util.display_path(loc.file) .. ':' .. loc.line, 'DtestLocation' })
  end
  if full and (r.stack_trace or '') ~= '' then
    lines[#lines + 1] = line()
    lines[#lines + 1] = line({ '  Stack trace', 'DtestDim' })
    for text in (r.stack_trace .. '\n'):gmatch('([^\n]*)\n') do
      lines[#lines + 1] = line({ text, 'DtestDim' })
    end
  end
  if full then output_section(lines, r.output or '') end
end

-- One test's latest result.
local function leaf_lines(lines, node)
  local status = node:status()
  local r = node.result
  local head = line()
  add(head, '  ')
  add(head, status_icon(status), status_hl(status, false))
  add(head, ' ')
  add(head, node:breadcrumb(), 'DtestBold')
  if status == 'running' or status == 'queued' then
    lines[#lines + 1] = head -- the glyph in the header says it all
    return
  end
  if not r then
    lines[#lines + 1] = head
    lines[#lines + 1] = line()
    lines[#lines + 1] = line({ '  Not run yet. Press ' .. config.key_for('run') .. ' to run it, '
      .. config.key_for('open-in-editor') .. ' to open it in the editor.', 'DtestDim' })
    return
  end
  if status == 'failed' then
    lines[#lines + 1] = head
    lines[#lines + 1] = line()
    failure_lines(lines, node, true)
    return
  end
  add(head, ' ')
  duration_segments(head, r.duration, false)
  lines[#lines + 1] = head
  lines[#lines + 1] = line()
  if status == 'skipped' then
    lines[#lines + 1] = line({ '  ' .. config.options.icons.skipped .. ' Skipped', 'DtestSkipped' })
    if (r.message or '') ~= '' then
      lines[#lines + 1] = line({ '  ' .. r.message, 'DtestDim' })
    end
  else
    lines[#lines + 1] = line({ '  ' .. config.options.icons.passed .. ' Passed in '
      .. util.duration(r.duration), 'DtestPassed' })
  end
  output_section(lines, r.output or '')
end

--- The log for a node: build errors first, then for a test its result,
--- message, stack trace and output; for a group every failure beneath it.
--- The group's tally is not repeated here, since the row it was selected
--- from carries it.
function M.node_log(session, node)
  local lines = {}
  local errs = build_errors(session.logs[session_mod.BUILD_LOG])
  if #errs > 0 then
    local head = line()
    add(head, '  ')
    add(head, ' BUILD ', 'DtestBadgeFail')
    add(head, ' ')
    add(head, vim.fs.basename(session.target), 'DtestBold')
    lines[#lines + 1] = head
    for _, text in ipairs(errs) do
      lines[#lines + 1] = M.output_line(text)
    end
    lines[#lines + 1] = line()
  end
  if not node then
    if #lines == 0 then
      lines[1] = line({ '  Select a project, class or test below; its results show here.', 'DtestDim' })
    end
    return lines
  end
  if node:is_leaf() then
    leaf_lines(lines, node)
    return lines
  end
  local c = node:counts()
  local status = node:status()
  local head = line()
  add(head, '  ')
  add(head, status_icon(status), status_hl(status, false))
  add(head, ' ')
  add(head, node:breadcrumb(), 'DtestBold')
  -- A time only goes up once its tests have all reported: until then it
  -- would be a running total pretending to be a result.
  local d = node:duration()
  if d > 0 and status ~= 'running' and status ~= 'queued' then
    add(head, ' ')
    duration_segments(head, d, false)
  end
  lines[#lines + 1] = head
  local failed = {}
  for _, l in ipairs(node:leaves()) do
    if l:status() == 'failed' and l.result then failed[#failed + 1] = l end
  end
  if #failed > 0 then
    for _, l in ipairs(failed) do
      lines[#lines + 1] = line()
      failure_lines(lines, l, false)
    end
  elseif c.running > 0 or c.queued > 0 then -- the glyph says it is going
  elseif c.passed + c.skipped > 0 then
    lines[#lines + 1] = line()
    lines[#lines + 1] = line({ '  ' .. config.options.icons.passed .. ' No failed tests.', 'DtestPassed' })
  else
    lines[#lines + 1] = line()
    lines[#lines + 1] = line({ '  Not run yet. Press ' .. config.key_for('run') .. ' to run it, '
      .. config.key_for('run-all') .. ' for everything.', 'DtestDim' })
  end
  return lines
end

--- The raw dotnet output of whichever run covers the node.
function M.output_log(session, node)
  local key = session:output_for(node)
  local out = session.logs[key] or {}
  local lines = {}
  if #out == 0 then
    lines[1] = line({ '  (no output yet)', 'DtestDim' })
    return lines
  end
  for i, text in ipairs(out) do
    lines[i] = M.output_line(text)
  end
  return lines
end

--- Whichever of the two the log pane is showing.
function M.log_lines(session, node)
  if session.show_output then return M.output_log(session, node) end
  return M.node_log(session, node)
end

-- The footer.

-- The three outcomes of a tally, each bold in its colour, or grey while it
-- is still zero, so the line keeps its shape as a run fills it in.
local function outcome_segments(l, c)
  local function part(n, label, hl)
    add(l, n .. ' ' .. label, n > 0 and hl or 'DtestDim')
  end
  part(c.failed, 'failed', 'DtestFailed')
  add(l, ' | ', 'DtestDim')
  part(c.passed, 'passed', 'DtestPassed')
  add(l, ' | ', 'DtestDim')
  part(c.skipped, 'skipped', 'DtestSkipped')
  return l
end

--- The last two lines of the screen: what the last batch of runs was, or
--- what dtest is doing or has to say instead, and under it how that batch
--- went. A message takes only the first line, so it never hides the results
--- it is usually about.
function M.footer_lines(session)
  local head = M.state_line(session)
  if not head then
    head = line()
    add(head, ' ')
    if not session.batch_start then
      add(head, 'nothing run yet', 'DtestDim')
    else
      local ran = session:batch_counts()
      local done = ran.failed + ran.passed + ran.skipped
      -- The clock time is a footnote, so it stays grey; how long the tests
      -- took is worth a glance, so it gets a quiet cyan.
      add(head, 'Ran ' .. util.plural(done, 'test') .. ' in ', 'DtestDim')
      add(head, util.duration(session:batch_duration()), 'DtestElapsed')
      add(head, ' at ' .. os.date('%H:%M:%S', session.batch_clock or os.time()), 'DtestDim')
    end
  end
  local outcomes = line()
  if session.batch_start then
    add(outcomes, ' ')
    outcome_segments(outcomes, session:batch_counts())
  end
  return { head, outcomes }
end

--- What dtest is doing: a message, or building or listing as plain text.
--- It is nil otherwise, before, during and after runs, since the tree's
--- spinner and the outcome row already say it.
function M.state_line(session)
  if session.message then
    local l = line()
    add(l, ' ')
    add(l, session.message.is_error and ' FAIL ' or ' INFO ',
      session.message.is_error and 'DtestBadgeFail' or 'DtestBadgeInfo')
    add(l, ' ' .. session.message.text)
    return l
  end
  if session.building then
    -- Progress, not news: grey, so it sits quietly until it has something
    -- to report.
    return line({ ' Building ' .. vim.fs.basename(session.target) .. '…', 'DtestDim' })
  end
  if session.loading > 0 then
    return line({ ' Listing tests…', 'DtestDim' })
  end
  return nil
end

-- Help.

-- The actions a line of the help covers; the keys it prints are looked up
-- when it is drawn, so a rebinding shows up there too.
local help_rows = {
  { { 'switch-pane' }, 'to switch between the log and the tree' },
  { { 'expand', 'collapse' }, 'to expand / collapse a project, class or theory' },
  { { 'expand-all', 'collapse-all' }, 'to expand / collapse the whole tree' },
  { { 'toggle-fold' }, 'to toggle a fold' },
  { { 'focus', 'unfocus' }, 'to focus on the selected project or class, treating its tests as the only ones, and to step back out' },
  { { 'run' }, 'to run the selected project, class or test' },
  { { 'run-all' }, 'to run the whole solution, or whatever is in focus' },
  { { 'run-failed' }, 'to rerun only the failed tests' },
  { { 'only-failed', 'only-skipped' }, 'to show only the failed / skipped tests' },
  { { 'show-all' }, 'to show all tests again (esc does too)' },
  { { 'cancel' }, 'to cancel the running tests' },
  { { 'next-failure', 'previous-failure' }, 'to jump to the next / previous failure' },
  { { 'open-in-editor' }, 'to open the source: a stack frame under the log cursor, else a failed test\'s failing line, else the declaration' },
  { { 'filter' }, 'to filter the tree by name (enter keeps it, esc clears every filter)' },
  { { 'toggle-output' }, 'to show the raw dotnet output of the selected project instead' },
  { { 'reload' }, 'to rebuild and list the tests again' },
  { { 'quit' }, 'to hide dtest, keeping the session and whatever is running (:DtestClose ends it)' },
}

--- vitest's "Watch Usage" list, drawn in the log pane; any key closes it.
function M.help_lines()
  local lines = {}
  for _, row in ipairs(help_rows) do
    local l = line()
    add(l, ' ')
    add(l, 'press', 'DtestDim')
    add(l, ' ')
    add(l, string.format('%-18s', config.keys_for(unpack(row[1]))), 'DtestKey')
    add(l, ' ' .. row[2])
    lines[#lines + 1] = l
  end
  lines[#lines + 1] = line()
  lines[#lines + 1] = line({ ' Motions are Neovim\'s own: j / k, gg / G, <C-d> / <C-u>, and in the log V and y select and yank.', 'DtestDim' })
  lines[#lines + 1] = line({ ' press any key to close this help', 'DtestDim' })
  return lines
end

--- A ⎯⎯ Title ⎯⎯⎯ winbar. The rule itself is faint so it only frames the
--- pane; the title carries the colour, bright when the pane is focused.
--- A title too long for a narrow pane keeps its end, since what is being
--- looked at reads there and the solution it belongs to is the least of
--- it.
function M.pane_title(title, focused, width)
  local rule = config.options.icons.rule
  local head = rule .. rule .. ' '
  local tail = rule .. rule
  local room = math.max(4, width - vim.fn.strdisplaywidth(head) - vim.fn.strdisplaywidth(tail) - 2)
  if vim.fn.strdisplaywidth(title) > room then
    title = '…' .. vim.fn.strcharpart(title, vim.fn.strchars(title) - room + 1)
  end
  -- Cells, not bytes: the rule is three bytes wide and one column wide,
  -- and counting the wrong one leaves the line short of the pane's edge.
  local fill = math.max(0, width - vim.fn.strdisplaywidth(head)
    - vim.fn.strdisplaywidth(title) - 1 - vim.fn.strdisplaywidth(tail))
  local function escape(s) return (s:gsub('%%', '%%%%')) end
  return table.concat({
    '%#DtestRule#', escape(head),
    focused and '%#DtestKey#' or '%#DtestDim#', escape(title),
    '%#DtestRule# ', escape(string.rep(rule, fill) .. tail), '%*',
  })
end

return M
