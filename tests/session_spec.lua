-- The session's own reading of the tree: which folders of tests there are
-- and what each one holds.
local t = require('tests.helper')
local session_mod = require('dtest.session')

local function built()
  local session = session_mod.new('/a/Shop.slnx', {})
  local core = session.tree:add_project('/a/tests/Shop.Core.Tests/Shop.Core.Tests.csproj')
  session.tree:set_tests(core, {
    'Shop.Core.Tests.Pricing.MoneyTests.Adds',
    'Shop.Core.Tests.Pricing.MoneyTests.Rounds(n: 1)',
    'Shop.Core.Tests.Pricing.Discounts.PercentTests.Halves',
    'Shop.Core.Tests.Orders.OrderTests.Totals',
    'Shop.Core.Tests.SanityTests.Runs', -- straight under the project
  })
  local api = session.tree:add_project('/a/tests/Shop.Api.Tests/Shop.Api.Tests.csproj')
  -- A namespace that does not begin with the project name, as a project
  -- with its own RootNamespace has.
  session.tree:set_tests(api, { 'Contoso.Api.PingTests.Pongs' })
  return session, core, api
end

local function paths(folders)
  local out = {}
  for _, folder in ipairs(folders) do
    out[#out + 1] = string.format('%s %d', folder.path, folder.count)
  end
  return out
end

return {
  { 'offers every namespace under a project, and the project itself', function()
    local session = built()
    t.eq({
      'Shop.Api.Tests 1',
      'Shop.Api.Tests/Contoso 1',     -- a namespace of its own is still folders
      'Shop.Api.Tests/Contoso/Api 1',
      'Shop.Core.Tests 5',
      'Shop.Core.Tests/Orders 1',
      'Shop.Core.Tests/Pricing 3',
      'Shop.Core.Tests/Pricing/Discounts 1',
    }, paths(session:folders()))
  end },

  { 'counts a folder by everything beneath it, nested folders included', function()
    local session = built()
    for _, folder in ipairs(session:folders()) do
      if folder.path == 'Shop.Core.Tests/Pricing' then
        t.eq(3, folder.count, 'two of MoneyTests and one of the folder under it')
        local names = {}
        for _, node in ipairs(session:classes_under(folder)) do
          names[#names + 1] = node.name
        end
        t.eq({ 'Pricing.Discounts.PercentTests', 'Pricing.MoneyTests' }, names)
      end
    end
  end },

  { 'runs a project as a whole rather than by its namespace', function()
    local session, core = built()
    for _, folder in ipairs(session:folders()) do
      if folder.path == 'Shop.Core.Tests' then
        t.eq(nil, folder.prefix, 'no filter, so a class in any namespace still runs')
        t.eq(core, folder.project)
        t.eq(4, #session:classes_under(folder))
      end
    end
  end },

  { 'lets what waits for the listing through once it is done', function()
    local session = session_mod.new('/a/Shop.slnx', {})
    local ran = 0
    session:when_listed(function() ran = ran + 1 end)
    t.eq(0, ran, 'nothing is listed yet')
    session.tree:add_project('/a/tests/Shop.Core.Tests/Shop.Core.Tests.csproj')
    session:flush_ready()
    t.eq(1, ran)
    session:when_listed(function() ran = ran + 1 end)
    t.eq(2, ran, 'and afterwards it is called at once')
  end },
}
