-- Drawing that is worth pinning down on its own.
local t = require('tests.helper')
local render = require('dtest.ui.render')
local tree = require('dtest.tree')

-- The text of a winbar, without its highlight groups.
local function plain(bar)
  return (bar:gsub('%%#%w+#', ''):gsub('%%%*', ''))
end

return {
  { 'frames a pane title with a rule across the rest of the line', function()
    local bar = plain(render.pane_title('Tests', true, 30))
    t.eq(30, vim.fn.strdisplaywidth(bar))
    t.matches('^⎯⎯ Tests ⎯', bar)
  end },

  { 'keeps the end of a title too long for the pane', function()
    local title = 'Log  Shop.Api.Tests › Middleware.RateLimitMiddlewareTests › OverLimit_Returns429'
    local bar = plain(render.pane_title(title, false, 30))
    t.eq(30, vim.fn.strdisplaywidth(bar), 'and still fills the line exactly')
    t.matches('OverLimit_Returns429', bar, 'the test being looked at reads')
    t.matches('…', bar)
  end },

  { 'wraps a duration in the colour of how slow it is', function()
    local quick = render.duration_segments(render.line(), 0.032, false)
    t.eq({ { '0.032', 'DtestQuick' }, { 's', 'DtestQuickUnit' } }, quick)
    local slow = render.duration_segments(render.line(), 1.5, false)
    t.eq({ { '1.5', 'DtestSlow' }, { 's', 'DtestSlowUnit' } }, slow)
    -- A compound form carries its unit inside the number, so it stays in
    -- one shade.
    t.eq({ { '2m34s', 'DtestTreeSlow' } }, render.duration_segments(render.line(), 154, true))
  end },

  { 'colours the two sides of a failed comparison', function()
    t.eq({ { '  ' }, { 'Expected: 429', 'DtestExpected' } },
      render.output_line('  Expected: 429'))
    t.eq({ { '' }, { 'Actual:   428', 'DtestActual' } }, render.output_line('Actual:   428'))
    t.eq({ { '$ dotnet test', 'DtestCommand' } }, render.output_line('$ dotnet test'))
    t.eq({ { '  Passed Ns.C.M', 'DtestPassed' } }, render.output_line('  Passed Ns.C.M'))
    t.eq({ { 'nothing in particular' } }, render.output_line('nothing in particular'))
  end },

  { 'colours a skipped test in the tree the way it colours a failed one', function()
    local tr = tree.new('Shop', '/a/Shop.slnx')
    local project = tr:add_project('/a/tests/Shop.Tests/Shop.Tests.csproj')
    tr:set_tests(project, {
      'Shop.Tests.Pricing.MoneyTests.Adds',
      'Shop.Tests.Pricing.MoneyTests.Rounds',
    })
    local adds, rounds = tr:leaves()[1], tr:leaves()[2]
    adds:set_status('skipped')
    rounds:set_status('failed')
    local function name_hl(node)
      for _, seg in ipairs(render.node_line(node, '', { spinner = '⠋' })) do
        if seg[1] == node.name then return seg[2] end
      end
    end
    t.eq('DtestTreeSkipped', name_hl(adds))
    t.eq('DtestTreeFailed', name_hl(rounds))
  end },

  { 'lists a group\'s skipped tests, with the reason each gave', function()
    local tr = tree.new('Shop', '/a/Shop.slnx')
    local project = tr:add_project('/a/tests/Shop.Tests/Shop.Tests.csproj')
    tr:set_tests(project, {
      'Shop.Tests.Pricing.MoneyTests.Adds',
      'Shop.Tests.Pricing.MoneyTests.Rounds',
    })
    local adds, rounds = tr:leaves()[1], tr:leaves()[2]
    adds:set_status('passed')
    adds.result = { duration = 0.01 }
    rounds:set_status('skipped')
    rounds.result = { duration = 0, message = 'Waiting on the pricing fix' }
    local lines = render.node_log({ logs = {}, target = '/a/Shop.slnx' }, project)
    local texts = {}
    for i, l in ipairs(lines) do texts[i] = render.text(l) end
    local skip, at = t.find_line(texts, 'MoneyTests › Rounds')
    t.matches(' SKIP ', skip, 'the skipped test wears the badge a failure does')
    t.eq('Waiting on the pricing fix', texts[at + 1], 'and gives the reason under it')
    -- Tagged like a failure's block, so o opens the test the cursor is on
    -- rather than the group it was selected from.
    t.eq(rounds, lines[at].node)
    t.eq(nil, t.find_line(texts, 'MoneyTests › Adds'), 'a passing test is not listed')
    t.ok(t.find_line(texts, 'No failed tests'))
  end },
}
