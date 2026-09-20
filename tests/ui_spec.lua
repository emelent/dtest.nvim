-- The panes, driven through the real session with dotnet stood in for.
local t = require('tests.helper')
local config = require('dtest.config')
local ui = require('dtest.ui')

local API = 'Shop.Api.Tests'
local CORE = 'Shop.Core.Tests'

local api_tests = {
  'Shop.Api.Tests.Middleware.RateLimitMiddlewareTests.OverLimit_Returns429',
  'Shop.Api.Tests.Middleware.RateLimitMiddlewareTests.UnderLimit_Passes',
  -- a theory, so the tree has a group inside the class to fold
  'Shop.Api.Tests.Middleware.RateLimitMiddlewareTests.Bursts_AreCounted(n: 1)',
  'Shop.Api.Tests.Middleware.RateLimitMiddlewareTests.Bursts_AreCounted(n: 2)',
}
local core_tests = {
  'Shop.Core.Tests.Pricing.MoneyTests.Adds',
  'Shop.Core.Tests.Pricing.MoneyTests.Rounds(n: 1)',
}

-- A solution on disk for the session to discover; dotnet itself never runs.
local function fixture()
  local dir = vim.fn.tempname()
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    local fd = io.open(path, 'w')
    fd:write(text)
    fd:close()
    return path
  end
  for _, name in ipairs({ API, CORE }) do
    write(dir .. '/tests/' .. name .. '/' .. name .. '.csproj',
      '<Project><ItemGroup><PackageReference Include="xunit" /></ItemGroup></Project>')
  end
  write(dir .. '/tests/' .. API .. '/RateLimitMiddlewareTests.cs', table.concat({
    'namespace Shop.Api.Tests.Middleware;', -- 1
    '',                                     -- 2
    'public class RateLimitMiddlewareTests', -- 3
    '{',                                    -- 4
    '    [Fact]',                           -- 5
    '    public void UnderLimit_Passes()',  -- 6
    '    {',                                -- 7
    '        Assert.True(true);',           -- 8
    '    }',                                -- 9
    '',                                     -- 10
    '    [Fact]',                           -- 11
    '    public void OverLimit_Returns429()', -- 12
    '    {',                                -- 13
    '        Assert.Equal(429, 428);',      -- 14
    '    }',                                -- 15
    '',                                     -- 16
    '    [Theory]',                         -- 17
    '    [InlineData(1)]',                  -- 18
    '    public void Bursts_AreCounted(int n)', -- 19
    '    {',                                -- 20
    '        Assert.True(n > 0);',          -- 21
    '    }',                                -- 22
    '}',                                    -- 23
  }, '\n'))
  return write(dir .. '/Shop.slnx', string.format(
    '<Solution><Project Path="tests/%s/%s.csproj" /><Project Path="tests/%s/%s.csproj" /></Solution>',
    API, API, CORE, CORE))
end

local commands = {}

-- The value of a flag in a dotnet command line, or nil when it is absent.
local function arg_of(cmd, flag)
  local i = vim.fn.index(cmd, flag)
  if i < 0 then return nil end
  return cmd[i + 2]
end

local function names_for(project)
  return project:find(API, 1, true) and api_tests or core_tests
end

-- Every listed test passes but OverLimit_Returns429, which fails with a
-- stack trace pointing into the fixture's source.
local function results_for(names)
  local results = {}
  for _, name in ipairs(names) do
    if name:find('OverLimit', 1, true) then
      results[#results + 1] = { name = name, outcome = 'Failed',
        message = 'Assert.Equal() Failure: Values differ\nExpected: 429\nActual:   428',
        stack = '   at ' .. name .. '() in ' .. commands.source .. ':line 4' }
    else
      results[#results + 1] = { name = name, outcome = 'Passed' }
    end
  end
  return results
end

-- The VSTest filter as dotnet reads it: = is the whole name, ~ is any
-- part of it, | is either of two.
local function matches(filter, name)
  if not filter or filter == '' then return true end
  for clause in vim.gsplit(filter, '|', { plain = true }) do
    local op, value = clause:match('^FullyQualifiedName([=~])(.*)$')
    if value then
      value = value:gsub('\\(.)', '%1')
      if op == '=' and value == name then return true end
      if op == '~' and name:find(value, 1, true) then return true end
    end
  end
  return false
end

local function console(names)
  local lines = { 'Test run for Shop.Tests.dll' }
  for _, r in ipairs(results_for(names)) do
    lines[#lines + 1] = string.format('  %s %s [1 ms]', r.outcome, r.name)
  end
  return lines
end

local function stub()
  t.stub_dotnet({
    build = { lines = { 'Build succeeded.' } },
    list = function(cmd)
      commands[#commands + 1] = cmd
      local names = names_for(cmd[3])
      local lines = { 'The following Tests are available:' }
      for _, n in ipairs(names) do lines[#lines + 1] = '    ' .. n end
      return { lines = lines }
    end,
    test = function(cmd)
      commands[#commands + 1] = cmd
      -- The root's run is one invocation over the solution, so it reports
      -- the tests of both projects at once.
      local names = cmd[3]:find('.slnx', 1, true)
        and vim.list_extend(vim.deepcopy(api_tests), core_tests)
        or names_for(cmd[3])
      local filter = arg_of(cmd, '--filter')
      names = vim.tbl_filter(function(n) return matches(filter, n) end, names)
      return { lines = console(names), trx = t.trx(results_for(names)) }
    end,
  })
end

-- Opens the panes over a fresh fixture and waits for the listing.
local function open(layout)
  commands = {}
  config.setup({ no_build = true, layout = layout })
  stub()
  local target = fixture()
  commands.source = vim.fs.dirname(target) .. '/tests/' .. API .. '/RateLimitMiddlewareTests.cs'
  ui.open(target)
  t.wait(function()
    local s = ui.session()
    return s and not s:busy() and s.tree:counts().total == 6
  end, 'the tests to be listed')
  ui.render()
  return ui.session()
end

local function close()
  ui.close()
  t.restore_dotnet()
end

local function tree_win()
  return vim.fn.bufwinid(t.pane_buf('tree') or -1)
end

local function select(pattern)
  local lines = t.lines('tree')
  local _, row = t.find_line(lines, pattern)
  t.ok(row, 'no tree row matching ' .. pattern .. '\n' .. table.concat(lines, '\n'))
  vim.api.nvim_win_set_cursor(tree_win(), { row, 0 })
  return ui.current()
end

-- Puts the fixture's source file in the window dtest was opened from and
-- goes there, which is where the cursor is when a run is asked for from
-- the code.
local function in_source_buffer(file)
  local panes = {}
  for _, name in ipairs({ 'tree', 'log', 'footer' }) do
    panes[t.pane_buf(name) or -1] = true
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if not panes[vim.api.nvim_win_get_buf(win)] then
      vim.api.nvim_set_current_win(win)
      vim.cmd('edit! ' .. vim.fn.fnameescape(file or commands.source))
      return win
    end
  end
  error('no window left for the code')
end

local function back_to_source(win)
  vim.api.nvim_set_current_win(win)
end

-- The window a pane is drawn in, and where it sits.
local function pane(name)
  return vim.fn.bufwinid(t.pane_buf(name) or -1)
end

local function row_of(win) return vim.api.nvim_win_get_position(win)[1] end
local function col_of(win) return vim.api.nvim_win_get_position(win)[2] end

local function run_and_wait()
  local s = ui.session()
  t.wait(function() return not s:busy() end, 'the run to finish')
  ui.render()
end

return {
  -- Whatever a case leaves behind, the next one starts from nothing open.
  after_each = function()
    ui.close()
    t.restore_dotnet()
    config.setup({})
  end,

  { 'lists the projects under a root that counts them', function()
    local s = open()
    t.eq(2, #s.tree.projects)
    local lines = t.lines('tree')
    t.matches('Shop %(2 projects | 6 tests%)', lines[1])
    t.eq(3, #lines) -- the root and two collapsed projects
    close()
  end },

  { 'expands a project into classes and its classes into tests', function()
    open()
    select('Shop%.Api%.Tests')
    ui.actions.expand()
    t.ok(t.find_line(t.lines('tree'), 'Middleware.RateLimitMiddlewareTests'))
    select('RateLimitMiddlewareTests')
    ui.actions.expand()
    t.ok(t.find_line(t.lines('tree'), 'OverLimit_Returns429'))
    close()
  end },

  { 'runs the whole solution in one dotnet test and records every result', function()
    local s = open()
    ui.actions['run-all']()
    run_and_wait()
    local last = commands[#commands]
    t.eq('test', last[2])
    t.matches('%.slnx$', last[3], 'the root runs the solution itself')
    t.eq(nil, arg_of(last, '--filter'))
    local counts = s.tree:counts()
    t.eq(5, counts.passed)
    t.eq(1, counts.failed)
    local footer = t.lines('footer')
    t.matches('Ran 6 tests in', footer[1])
    t.matches('1 failed | 5 passed | 0 skipped', footer[2])
    close()
  end },

  { 'runs one class with a prefix filter', function()
    open()
    select('Shop%.Api%.Tests')
    ui.actions.expand()
    local class = select('RateLimitMiddlewareTests')
    ui.actions.run()
    run_and_wait()
    local last = commands[#commands]
    t.matches('Shop%.Api%.Tests%.csproj$', last[3], 'a class runs inside its project')
    t.eq('FullyQualifiedName~Shop.Api.Tests.Middleware.RateLimitMiddlewareTests.',
      arg_of(last, '--filter'))
    t.eq('failed', class:status())
    t.eq(4, class:counts().total)
    close()
  end },

  { 'shows a failure with its message and location in the log', function()
    open()
    ui.actions['run-all']()
    run_and_wait()
    select('OverLimit_Returns429')
    ui.render()
    local log = t.lines('log')
    t.matches('OverLimit_Returns429', log[1], 'the header names the test')
    t.ok(t.find_line(log, 'FAIL'))
    t.ok(t.find_line(log, 'Expected: 429'))
    t.ok(t.find_line(log, 'Actual:   428'))
    t.ok(t.find_line(log, 'RateLimitMiddlewareTests%.cs:4'))
    t.ok(t.find_line(log, 'Stack trace'))
    close()
  end },

  { 'narrows the tree to the failures and back', function()
    local s = open()
    ui.actions['run-all']()
    run_and_wait()
    ui.actions['only-failed']()
    local rows = s:rows()
    t.eq('OverLimit_Returns429', rows[#rows].name)
    t.eq(4, #rows) -- root, project, class, the one failure
    ui.actions['show-all']()
    t.eq(nil, s.status_filter)
    close()
  end },

  { 'filters the tree by name', function()
    local s = open()
    s.query = 'underlimit'
    ui.render()
    local rows = s:rows()
    t.eq('UnderLimit_Passes', rows[#rows].name)
    t.eq(4, #rows)
    ui.actions.clear()
    t.eq('', s.query)
    close()
  end },

  { 'focuses on a project and steps back out', function()
    local s = open()
    local project = select('Shop%.Api%.Tests')
    ui.actions.focus()
    t.eq(project, s.zoom)
    t.eq(project, s:rows()[1], 'the focused node becomes the root of the tree')
    ui.actions['run-all']()
    run_and_wait()
    t.matches('Shop%.Api%.Tests%.csproj$', commands[#commands][3], 'run-all runs what is in focus')
    ui.actions.unfocus()
    t.eq(nil, s.zoom)
    close()
  end },

  { 'jumps to the next failure', function()
    local s = open()
    ui.actions['run-all']()
    run_and_wait()
    select('Shop %(')
    ui.actions['next-failure']()
    t.eq('OverLimit_Returns429', ui.current().name)
    close()
  end },

  { 'swaps the report for the raw dotnet output', function()
    local s = open()
    ui.actions['run-all']()
    run_and_wait()
    ui.actions['toggle-output']()
    ui.render()
    local log = t.lines('log')
    t.matches('^%$ dotnet test', log[1])
    t.ok(t.find_line(log, 'Passed Shop%.Core%.Tests%.Pricing%.MoneyTests%.Adds'))
    ui.actions['toggle-output']()
    t.eq(false, s.show_output)
    close()
  end },

  { 'opens a failing test at the line its stack trace names', function()
    open()
    ui.actions['run-all']()
    run_and_wait()
    select('Shop%.Api%.Tests')
    ui.actions.expand()
    select('RateLimitMiddlewareTests')
    ui.actions.expand()
    select('OverLimit_Returns429')
    ui.actions['open-in-editor']()
    t.matches('RateLimitMiddlewareTests%.cs$', vim.api.nvim_buf_get_name(0))
    t.eq(4, vim.api.nvim_win_get_cursor(0)[1])
    ui.close()
    t.restore_dotnet()
  end },

  { 'queues runs and cancels the queue', function()
    local s = open()
    select('Shop%.Api%.Tests')
    ui.actions.run()
    select('Shop%.Core%.Tests')
    ui.actions.run()
    t.ok(s.run ~= nil or #s.queue > 0, 'something is running or waiting')
    run_and_wait()
    t.eq(0, #s.queue)
    t.eq(6, s.tree:counts().passed + s.tree:counts().failed)
    s:cancel()
    t.matches('Nothing is running', s.message.text)
    close()
  end },

  { 'shows the help over the log and closes again', function()
    open()
    ui.actions.help()
    ui.render()
    t.ok(t.find_line(t.lines('log'), 'press any key to close this help'))
    ui.actions.clear()
    ui.render()
    t.eq(nil, t.find_line(t.lines('log'), 'press any key to close this help'))
    close()
  end },

  { 'keeps what the prompt accepts and drops it on esc', function()
    local s = open()
    local prompt = require('dtest.ui.prompt')
    -- The prompt is typed into for real in use; here the text is put in
    -- place and the change announced, since neither startinsert nor
    -- TextChangedI happens inside a test that never returns to the loop.
    local function type_into(text)
      local buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '? Filter › ' .. text })
      vim.api.nvim_exec_autocmds('TextChangedI', { buffer = buf })
    end

    ui.actions.filter()
    t.ok(prompt.is_open(), 'the prompt is open')
    type_into('underlimit')
    t.eq('underlimit', s.query, 'the tree narrows as it is typed')
    t.eq('UnderLimit_Passes', s:rows()[#s:rows()].name)
    vim.api.nvim_feedkeys(vim.keycode('A<CR>'), 'xt', false)
    t.eq('underlimit', s.query, 'enter keeps the filter')
    t.ok(not prompt.is_open(), 'and closes the prompt')

    ui.actions.filter()
    type_into('money')
    vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'xt', false)
    t.eq('', s.query, 'esc drops every filter')
    t.ok(not prompt.is_open())
    close()
  end },

  { 'leaves out the summary lines when the layout says so', function()
    config.setup({ no_build = true, layout = { footer = false } })
    stub()
    ui.open(fixture())
    t.wait(function()
      local s = ui.session()
      return s and not s:busy() and s.tree:counts().total == 6
    end, 'the tests to be listed')
    t.eq(nil, t.pane_buf('footer'), 'no summary buffer at all')
    t.eq(3, #vim.api.nvim_tabpage_list_wins(0), 'the code, the log and the tree')
    ui.actions['run-all']()
    run_and_wait() -- nowhere to draw the summary, but the run still lands
    t.eq(1, ui.session().tree:counts().failed)
    close()
    config.setup({})
  end },

  { 'takes a directory, or nothing at all, and finds the solution in it', function()
    config.setup({ no_build = true })
    stub()
    local target = fixture()
    commands.source = ''
    ui.open(vim.fs.dirname(target))
    t.wait(function()
      local s = ui.session()
      return s and not s:busy() and s.tree:counts().total == 6
    end, 'the tests to be listed')
    t.eq(target, ui.session().target)
    close()
  end },

  { 'runs the tests of the file in the buffer, without leaving it', function()
    open()
    local source = in_source_buffer()
    require('dtest').run_file({})
    run_and_wait()
    t.matches('RateLimitMiddlewareTests%.cs$', vim.api.nvim_buf_get_name(0),
      'the cursor stays in the code; the panes are beside it to be glanced at')
    t.eq('FullyQualifiedName~Shop.Api.Tests.Middleware.RateLimitMiddlewareTests.',
      arg_of(commands[#commands], '--filter'))
    t.ok(t.find_line(t.lines('tree'), 'OverLimit_Returns429'), 'the tree opens on what ran')
    local s = ui.session()
    t.eq('Middleware.RateLimitMiddlewareTests', s.zoom.name, "the tree narrows to the file's class")
    t.eq(s.zoom, s:rows()[1], 'which becomes the root of the tree')
    t.matches('MiddlewareTests', vim.wo[pane('tree')].winbar,
      'and the title says what is in focus')
    ui.actions.unfocus()
    t.eq('Shop.Api.Tests', s.zoom.name, 'and steps back out a level at a time')
    ui.actions.unfocus()
    t.eq(nil, s.zoom)
    close()
  end },

  { 'opens every test of the file, and a run does not fold them away', function()
    open()
    local source = in_source_buffer()
    require('dtest').run_file({})
    run_and_wait()
    local lines = t.lines('tree')
    t.ok(t.find_line(lines, 'Bursts_AreCounted'), 'the theory is there')
    t.ok(t.find_line(lines, '%(n: 1%)'), 'and is unfolded, though it passed')
    t.ok(t.find_line(lines, '%(n: 2%)'))
    -- Only that batch holds its folds; a run from the panes reads as a
    -- report again, passing groups folded away.
    ui.actions['run-all']()
    run_and_wait()
    t.eq(nil, t.find_line(t.lines('tree'), '%(n: 1%)'), 'the passing theory folds')
    close()
  end },

  { 'goes to the panes when it is asked to', function()
    open()
    in_source_buffer()
    require('dtest').run_file({ focus = true })
    run_and_wait()
    t.eq(t.pane_buf('tree'), vim.api.nvim_get_current_buf(), 'which is what the bang does')
    t.eq(1, ui.session().tree:counts().failed)
    close()
  end },

  { 'opens the panes for a run without moving into them', function()
    commands = {}
    config.setup({ no_build = true })
    stub()
    local target = fixture()
    commands.source = vim.fs.dirname(target) .. '/tests/' .. API .. '/RateLimitMiddlewareTests.cs'
    vim.cmd('edit! ' .. vim.fn.fnameescape(commands.source))
    config.options.target = target
    require('dtest').run_all()
    t.wait(function() return ui.is_open() and ui.session().batch_end ~= nil end, 'the run to finish')
    t.matches('RateLimitMiddlewareTests%.cs$', vim.api.nvim_buf_get_name(0),
      'opened beside the code, not over it')
    t.eq(6, ui.session().tree:counts().passed + ui.session().tree:counts().failed,
      'and it waited for the listing before running')
    close()
  end },

  { 'runs the test the cursor is on', function()
    open()
    local source = in_source_buffer()
    require('dtest').run_nearest({ line = 13 }) -- inside OverLimit_Returns429
    run_and_wait()
    t.eq('FullyQualifiedName=Shop.Api.Tests.Middleware.RateLimitMiddlewareTests.OverLimit_Returns429',
      arg_of(commands[#commands], '--filter'))

    back_to_source(source)
    vim.api.nvim_win_set_cursor(0, { 6, 0 }) -- the other test, from the real cursor
    require('dtest').run_nearest()
    run_and_wait()
    t.eq('FullyQualifiedName=Shop.Api.Tests.Middleware.RateLimitMiddlewareTests.UnderLimit_Passes',
      arg_of(commands[#commands], '--filter'))
    t.eq('Middleware.RateLimitMiddlewareTests', ui.session().zoom.name,
      'one test focuses the class it is in, never the test itself')
    close()
  end },

  { 'reads an attribute line as the test under it, and the class above them all', function()
    open()
    local source = in_source_buffer()
    require('dtest').run_nearest({ line = 11 }) -- the [Fact] over OverLimit
    run_and_wait()
    t.eq('FullyQualifiedName=Shop.Api.Tests.Middleware.RateLimitMiddlewareTests.OverLimit_Returns429',
      arg_of(commands[#commands], '--filter'))

    back_to_source(source)
    require('dtest').run_nearest({ line = 1 }) -- above the first test
    run_and_wait()
    t.eq('FullyQualifiedName~Shop.Api.Tests.Middleware.RateLimitMiddlewareTests.',
      arg_of(commands[#commands], '--filter'), 'the class is what the cursor is on')
    close()
  end },

  { 'says so when a buffer holds no tests it knows, and stays put', function()
    local s = open()
    local ran = #commands
    in_source_buffer(vim.fs.dirname(s.target) .. '/Program.cs')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'public class Program { static void Main() {} }' })
    require('dtest').run_file({})
    t.matches('No listed tests', s.message.text)
    t.eq(ran, #commands, 'and runs nothing')
    t.matches('Program%.cs$', vim.api.nvim_buf_get_name(0),
      'nothing to watch, so nothing to move to')
    close()
  end },

  { 'takes a fifth of the window it opens beside, and no less than reads', function()
    open({ position = 'right' })
    -- A fifth of the 80 columns a headless editor has is too narrow to
    -- read, so the floor stands; the code keeps the rest either way.
    t.eq(30, vim.api.nvim_win_get_width(pane('log')))
    close()
    open({ position = 'right', size = 0.5 })
    t.eq(40, vim.api.nvim_win_get_width(pane('log')), 'a size asked for is taken as it stands')
    close()
    open({ position = 'below' })
    -- Under the code there is no code to crowd, so the panes take the
    -- greater part of the height rather than a fifth of it.
    local area = vim.api.nvim_win_get_height(pane('log'))
      + vim.api.nvim_win_get_height(pane('footer'))
    t.ok(area >= math.floor(vim.o.lines * 0.5), 'got ' .. area .. ' of ' .. vim.o.lines)
    close()
  end },

  { 'reads a space as wide only once it is comfortably wider than tall', function()
    t.eq('horizontal', ui.direction_for(200, 50))
    t.eq('vertical', ui.direction_for(100, 50), 'a cell is twice as tall as it is wide')
    t.eq('vertical', ui.direction_for(80, 40))
    config.setup({ layout = { direction = 'vertical' } })
    t.eq('vertical', ui.direction_for(400, 20), 'the config pins it whatever the shape')
    config.setup({})
  end },

  { 'stacks the log over the tree, 70 to 30', function()
    open({ direction = 'vertical', size = 0.9 })
    local log, tree, footer = pane('log'), pane('tree'), pane('footer')
    t.ok(row_of(log) < row_of(tree), 'the log is on top')
    t.eq(col_of(log), col_of(tree), 'stacked, so they start in the same column')
    local body = vim.api.nvim_win_get_height(log) + vim.api.nvim_win_get_height(tree)
    t.ok(math.abs(vim.api.nvim_win_get_height(log) - body * 0.7) <= 1,
      'the log takes about seven tenths of the height')
    t.eq(2, vim.api.nvim_win_get_height(footer))
    t.ok(row_of(footer) > row_of(tree), 'and the summary is along the bottom')
    close()
  end },

  { 'sits the tree left of the log, 30 to 70, with the summary under both', function()
    open({ direction = 'horizontal', size = 0.9 })
    local log, tree, footer = pane('log'), pane('tree'), pane('footer')
    t.ok(col_of(tree) < col_of(log), 'the tree is on the left')
    t.eq(row_of(tree), row_of(log), 'side by side, so they start on the same row')
    local width = vim.api.nvim_win_get_width(tree) + vim.api.nvim_win_get_width(log) + 1
    t.ok(math.abs(vim.api.nvim_win_get_width(tree) - width * 0.3) <= 1,
      'the tree takes about three tenths of the width')
    t.eq(width, vim.api.nvim_win_get_width(footer), 'the summary spans both panes')
    t.ok(row_of(footer) > row_of(log))
    close()
  end },

  { 'turns the panes round when the space changes shape', function()
    open({ direction = 'vertical', size = 0.9 })
    t.ok(row_of(pane('log')) < row_of(pane('tree')))
    config.setup({ no_build = true, layout = { direction = 'horizontal', size = 0.9 } })
    ui.reorient()
    ui.resize()
    t.ok(col_of(pane('tree')) < col_of(pane('log')), 'the tree moved beside the log')
    t.eq(row_of(pane('tree')), row_of(pane('log')))
    ui.reorient() -- and back again
    t.eq('horizontal', ui.direction_for(400, 20), 'still pinned')
    config.setup({ no_build = true, layout = { direction = 'vertical', size = 0.9 } })
    ui.reorient()
    t.ok(row_of(pane('log')) < row_of(pane('tree')), 'and back under it')
    close()
  end },

  { 'leaves the editor standing when the panes were all there was', function()
    open()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
      if not ft:match('^dtest') then pcall(vim.api.nvim_win_close, win, true) end
    end
    close()
    t.eq(1, #vim.api.nvim_tabpage_list_wins(0), 'a window is left in their place')
    t.eq(false, ui.is_open())
  end },

  { 'lists the folders of tests, the projects and their namespaces', function()
    local s = open()
    local paths = {}
    for _, folder in ipairs(s:folders()) do
      paths[#paths + 1] = folder.path .. ' (' .. folder.count .. ')'
    end
    t.eq({
      'Shop.Api.Tests (4)',
      'Shop.Api.Tests/Middleware (4)',
      'Shop.Core.Tests (2)',
      'Shop.Core.Tests/Pricing (2)',
    }, paths)
    close()
  end },

  { 'runs a folder with one filter over its namespace', function()
    open()
    require('dtest').run_folder({ path = 'Shop.Api.Tests/Middleware' })
    run_and_wait()
    local last = commands[#commands]
    t.matches('Shop%.Api%.Tests%.csproj$', last[3], 'inside the project that holds it')
    t.eq('FullyQualifiedName~Shop.Api.Tests.Middleware.', arg_of(last, '--filter'),
      'one prefix, not one expression per class')
    t.eq(1, ui.session().tree:counts().failed)
    t.eq('Middleware.RateLimitMiddlewareTests', ui.session().zoom.name,
      'the view goes to what the folder holds, one class here')
    t.ok(t.find_line(t.lines('tree'), 'OverLimit_Returns429'), 'with the folder opened up')
    close()
  end },

  { 'runs a whole project unfiltered when that is the folder chosen', function()
    open()
    require('dtest').run_folder({ path = 'Shop.Core.Tests' })
    run_and_wait()
    local last = commands[#commands]
    t.matches('Shop%.Core%.Tests%.csproj$', last[3])
    t.eq(nil, arg_of(last, '--filter'), 'a project runs as it is')
    close()
  end },

  { 'says so when the folder asked for is not one', function()
    local s = open()
    local ran = #commands
    require('dtest').run_folder({ path = 'Shop.Api.Tests/Nowhere' })
    t.matches('No folder of tests called', s.message.text)
    t.eq(ran, #commands)
    close()
  end },

  { 'asks which folder, through the picker the editor has', function()
    open()
    local asked, chosen
    local select = vim.ui.select
    vim.ui.select = function(items, opts, on_choice)
      asked = { items = items, prompt = opts.prompt, shown = opts.format_item(items[2]) }
      chosen = on_choice
    end
    require('dtest').run_folder({})
    vim.ui.select = select
    t.eq(4, #asked.items, 'every folder is offered')
    t.matches('Shop%.Api%.Tests/Middleware%s+4 tests', asked.shown, 'with what is under it')
    chosen(asked.items[2]) -- Shop.Api.Tests/Middleware
    run_and_wait()
    t.eq('FullyQualifiedName~Shop.Api.Tests.Middleware.', arg_of(commands[#commands], '--filter'))
    close()
  end },

  { 'prefers Snacks when it is installed', function()
    open()
    local given
    package.loaded.snacks = { picker = { pick = function(o) given = o end } }
    require('dtest').run_folder({})
    package.loaded.snacks = nil
    t.ok(given, 'the picker was opened')
    t.eq('dtest folders', given.title)
    t.eq('Shop.Api.Tests', given.items[1].text, 'matched on the path')
    local row = given.format(given.items[2])
    t.eq('Shop.Api.Tests/Middleware', row[1][1])
    t.matches('4 tests', row[3][1])
    -- Confirming runs it, the way the picker would.
    local closed = false
    given.actions.confirm({ close = function() closed = true end }, given.items[2])
    t.ok(closed, 'and the picker closes first')
    vim.wait(200, function() return #ui.session().queue > 0 or ui.session().run ~= nil end, 10)
    run_and_wait()
    t.eq('FullyQualifiedName~Shop.Api.Tests.Middleware.', arg_of(commands[#commands], '--filter'))
    close()
  end },

  { 'binds the keys the config names', function()
    config.setup({ no_build = true, keys = { run = { 'R' } } })
    stub()
    ui.open(fixture())
    t.wait(function()
      local s = ui.session()
      return s and not s:busy() and s.tree:counts().total == 6
    end, 'the tests to be listed')
    local buf = t.pane_buf('tree')
    local keys = {}
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      keys[map.lhs] = map.desc
    end
    t.eq('dtest run', keys.R)
    t.eq(nil, keys.r, 'the default is replaced, not added to')
    close()
    config.setup({})
  end },
}
