-- The node model: how display names become a tree, and how status, counts
-- and durations roll up through it.
local t = require('tests.helper')
local tree = require('dtest.tree')

local names = {
  'Shop.Tests.Pricing.MoneyTests.Adds',
  'Shop.Tests.Pricing.MoneyTests.Rounds(n: 1)',
  'Shop.Tests.Pricing.MoneyTests.Rounds(n: 2)',
  'Shop.Tests.Orders.OrderTests.Totals',
}

local function built()
  local tr = tree.new('Shop', '/a/Shop.slnx')
  local project = tr:add_project('/a/tests/Shop.Tests/Shop.Tests.csproj')
  tr:set_tests(project, names)
  return tr, project
end

return {
  { 'splits display names, brackets and all', function()
    t.eq({ 'Ns.Sub', 'Class', 'Method', '' }, { tree.split_name('Ns.Sub.Class.Method') })
    t.eq({ 'Ns', 'Class', 'Method', '(n: 1)' }, { tree.split_name('Ns.Class.Method(n: 1)') })
    t.eq({ 'Ns', 'Class', 'Method', '(s: "a.b")' }, { tree.split_name('Ns.Class.Method(s: "a.b")') })
    t.eq({ '', 'Class', 'Method', '' }, { tree.split_name('Class.Method') })
  end },

  { 'builds project, class, method and case nodes', function()
    local tr, project = built()
    t.eq(2, #project.children)
    local classes = {}
    for _, c in ipairs(project.children) do classes[#classes + 1] = c.name end
    t.eq({ 'Orders.OrderTests', 'Pricing.MoneyTests' }, classes) -- the project prefix is dropped
    local money = project.children[2]
    t.eq({ 'Adds', 'Rounds' }, { money.children[1].name, money.children[2].name })
    t.eq(2, #money.children[2].children) -- the theory's two rows
    t.eq('case', money.children[2].children[1].kind)
    t.eq(4, #tr:leaves())
  end },

  { 'rolls status up: running beats queued beats failed beats passed', function()
    local tr, project = built()
    local leaves = tr:leaves()
    for _, l in ipairs(leaves) do l:set_status('passed') end
    t.eq('passed', project:status())
    leaves[1]:set_status('failed')
    t.eq('failed', project:status())
    leaves[2]:set_status('queued')
    t.eq('queued', project:status())
    leaves[3]:set_status('running')
    t.eq('running', project:status())
  end },

  { 'counts and sums the leaves under a node', function()
    local tr, project = built()
    local leaves = tr:leaves()
    leaves[1]:set_status('failed')
    leaves[1].result = { duration = 0.5 }
    leaves[2]:set_status('passed')
    leaves[2].result = { duration = 0.25 }
    local c = project:counts()
    t.eq(4, c.total)
    t.eq(1, c.failed)
    t.eq(1, c.passed)
    t.eq(0.75, project:duration())
  end },

  { 'builds the filters a run is pointed at', function()
    local _, project = built()
    local money = project.children[2]
    t.eq('', project:filter())
    t.eq('FullyQualifiedName~Shop.Tests.Pricing.MoneyTests.', money:filter())
    t.eq('FullyQualifiedName=Shop.Tests.Pricing.MoneyTests.Adds', money.children[1]:filter())
    -- A theory row cannot be addressed on its own, so it runs its method.
    t.eq(money.children[2]:filter(), money.children[2].children[1]:filter())
  end },

  { 'hides the children of collapsed nodes', function()
    local tr, project = built()
    t.eq(2, #tr:visible_from(tr.root, '', nil)) -- the root and the collapsed project
    project.expanded = true
    t.eq(4, #tr:visible_from(tr.root, '', nil)) -- and now its two classes
  end },

  { 'a query brings matching leaves and their ancestors along', function()
    local tr = built()
    local rows = tr:visible_from(tr.root, 'rounds', nil)
    local names_seen = {}
    for _, n in ipairs(rows) do names_seen[#names_seen + 1] = n.name end
    t.eq({ 'Shop', 'Shop.Tests', 'Pricing.MoneyTests', 'Rounds', '(n: 1)', '(n: 2)' }, names_seen)
  end },

  { 'a status filter keeps only the leaves in that status', function()
    local tr = built()
    local leaves = tr:leaves()
    leaves[1]:set_status('failed')
    local rows = tr:visible_from(tr.root, '', 'failed')
    t.eq(leaves[1], rows[#rows])
    t.eq(4, #rows) -- root, project, class, the one failure
    t.eq(0, #tr:visible_from(tr.root, '', 'skipped'))
  end },

  { 'a finished run opens what failed and folds what passed', function()
    local tr, project = built()
    local leaves = tr:leaves()
    for _, l in ipairs(leaves) do l:set_status('passed') end
    leaves[1]:set_status('failed') -- Orders.OrderTests.Totals
    tr:fold_by_result(project)
    t.ok(project.expanded, 'the project is opened by a failure')
    t.ok(project.children[1].expanded, 'the failing class is opened')
    t.ok(not project.children[2].expanded, 'the passing class is folded')
  end },

  { 'a solution-wide result is filed under the project that listed it', function()
    local tr, project = built()
    local other = tr:add_project('/a/tests/Other.Tests/Other.Tests.csproj')
    tr:set_tests(other, { 'Other.Tests.Api.PingTests.Pongs' })
    t.eq(tr:leaf(project, names[1]), tr:leaf_in(tr.root, names[1]))
    t.eq(tr:leaf(other, 'Other.Tests.Api.PingTests.Pongs'), tr:leaf_in(tr.root, 'Other.Tests.Api.PingTests.Pongs'))
    -- A test that was never listed goes to the project its name prefixes.
    local fresh = tr:leaf_in(tr.root, 'Other.Tests.Api.PingTests.Added')
    t.eq(other, fresh:project())
  end },

  { 'relisting keeps results and folds of the tests that remain', function()
    local tr, project = built()
    local leaf = tr:leaf(project, names[1])
    leaf:set_status('failed')
    leaf.result = { duration = 2 }
    project.expanded = true
    tr:set_tests(project, names)
    local again = tr:leaf(project, names[1])
    t.eq('failed', again:status())
    t.eq(2, again.result.duration)
    t.ok(project.expanded)
  end },
}
