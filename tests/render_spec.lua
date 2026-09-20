-- Drawing that is worth pinning down on its own.
local t = require('tests.helper')
local render = require('dtest.ui.render')

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
}
