-- The panes, driven through the real session with dotnet stood in for.
local t = require('tests.helper')
local config = require('dtest.config')
local ui = require('dtest.ui')

local API = 'Shop.Api.Tests'
local CORE = 'Shop.Core.Tests'

local api_tests = {
  'Shop.Api.Tests.Middleware.RateLimitMiddlewareTests.OverLimit_Returns429',
  'Shop.Api.Tests.Middleware.RateLimitMiddlewareTests.UnderLimit_Passes',
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
    'namespace Shop.Api.Tests.Middleware;',
    'public class RateLimitMiddlewareTests',
    '{',
    '    [Fact] public void OverLimit_Returns429() { }',
    '}',
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

local function console(names)
  local lines = { 'Test run for ' .. names[1] }
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
      if filter then
        names = vim.tbl_filter(function(n)
          return filter:find(n, 1, true) ~= nil or filter:find(n:match('^(.*)%.[^%.]+$'), 1, true) ~= nil
        end, names)
      end
      return { lines = console(names), trx = t.trx(results_for(names)) }
    end,
  })
end

-- Opens the panes over a fresh fixture and waits for the listing.
local function open()
  commands = {}
  config.setup({ no_build = true })
  stub()
  local target = fixture()
  commands.source = vim.fs.dirname(target) .. '/tests/' .. API .. '/RateLimitMiddlewareTests.cs'
  ui.open(target)
  t.wait(function()
    local s = ui.session()
    return s and not s:busy() and s.tree:counts().total == 4
  end, 'the tests to be listed')
  ui.render()
  return ui.session()
end

local function close()
  ui.close()
  t.restore_dotnet()
end

local function tree_win()
  return vim.fn.bufwinid(vim.fn.bufnr(ui.buffer_names.tree))
end

local function select(pattern)
  local lines = t.lines('tree')
  local _, row = t.find_line(lines, pattern)
  t.ok(row, 'no tree row matching ' .. pattern .. '\n' .. table.concat(lines, '\n'))
  vim.api.nvim_win_set_cursor(tree_win(), { row, 0 })
  return ui.current()
end

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
    t.matches('Shop %(2 projects | 4 tests%)', lines[1])
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
    t.eq(3, counts.passed)
    t.eq(1, counts.failed)
    local footer = t.lines('footer')
    t.matches('Ran 4 tests in', footer[1])
    t.matches('1 failed | 3 passed | 0 skipped', footer[2])
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
    t.eq(2, class:counts().total)
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
    t.eq(4, s.tree:counts().passed + s.tree:counts().failed)
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
      return s and not s:busy() and s.tree:counts().total == 4
    end, 'the tests to be listed')
    t.eq(2, #vim.api.nvim_tabpage_list_wins(0), 'the log and the tree, and nothing else')
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
      return s and not s:busy() and s.tree:counts().total == 4
    end, 'the tests to be listed')
    t.eq(target, ui.session().target)
    close()
  end },

  { 'binds the keys the config names', function()
    config.setup({ no_build = true, keys = { run = { 'R' } } })
    stub()
    ui.open(fixture())
    t.wait(function()
      local s = ui.session()
      return s and not s:busy() and s.tree:counts().total == 4
    end, 'the tests to be listed')
    local buf = vim.fn.bufnr(ui.buffer_names.tree)
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
