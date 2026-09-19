-- The dotnet layer: finding projects, reading what the CLI prints and
-- reading the results file it leaves behind.
local t = require('tests.helper')
local filter = require('dtest.dotnet.filter')
local run = require('dtest.dotnet.run')
local solution = require('dtest.dotnet.solution')
local trx = require('dtest.dotnet.trx')
local util = require('dtest.util')

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  return dir
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local fd = io.open(path, 'w')
  fd:write(text)
  fd:close()
  return path
end

return {
  { 'recognises solution and project files', function()
    t.ok(solution.is_solution_file('Shop.sln'))
    t.ok(solution.is_solution_file('/a/b/Shop.SLNX'))
    t.ok(not solution.is_solution_file('Shop.csproj'))
    t.ok(solution.is_project_file('Shop.csproj'))
    t.ok(solution.is_project_file('Shop.fsproj'))
    t.ok(not solution.is_project_file('Shop.txt'))
  end },

  { 'parses a classic .sln', function()
    local text = table.concat({
      'Microsoft Visual Studio Solution File, Format Version 12.00',
      'Project("{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}") = "Shop.Core", "src\\Shop.Core\\Shop.Core.csproj", "{A}"',
      'Project("{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}") = "Shop.Tests", "tests\\Shop.Tests\\Shop.Tests.csproj", "{B}"',
      'Global',
    }, '\n')
    t.eq({ 'src\\Shop.Core\\Shop.Core.csproj', 'tests\\Shop.Tests\\Shop.Tests.csproj' }, solution.parse_sln(text))
  end },

  { 'parses an .slnx, nested folders and all', function()
    local text = [[
<Solution>
  <Folder Name="/src/"><Project Path="src/Shop.Core/Shop.Core.csproj" /></Folder>
  <Folder Name="/tests/">
    <Project Path="tests/Shop.Tests/Shop.Tests.csproj" />
  </Folder>
</Solution>]]
    t.eq({ 'src/Shop.Core/Shop.Core.csproj', 'tests/Shop.Tests/Shop.Tests.csproj' }, solution.parse_slnx(text))
  end },

  { 'keeps only the test projects of a solution', function()
    local dir = tmpdir()
    write(dir .. '/src/Lib/Lib.csproj', '<Project Sdk="Microsoft.NET.Sdk"></Project>')
    write(dir .. '/tests/Lib.Tests/Lib.Tests.csproj',
      '<Project><ItemGroup><PackageReference Include="xunit" /></ItemGroup></Project>')
    local sln = write(dir .. '/Shop.slnx',
      '<Solution><Project Path="src/Lib/Lib.csproj" /><Project Path="tests/Lib.Tests/Lib.Tests.csproj" /></Solution>')
    t.eq({ dir .. '/tests/Lib.Tests/Lib.Tests.csproj' }, solution.projects(sln))
  end },

  { 'falls back to every project when none looks like a test one', function()
    local dir = tmpdir()
    write(dir .. '/src/Lib/Lib.csproj', '<Project></Project>')
    local sln = write(dir .. '/Shop.slnx', '<Solution><Project Path="src/Lib/Lib.csproj" /></Solution>')
    t.eq({ dir .. '/src/Lib/Lib.csproj' }, solution.projects(sln))
  end },

  { 'prefers a solution over a project when picking a target', function()
    local dir = tmpdir()
    write(dir .. '/B.csproj', '')
    write(dir .. '/A.slnx', '<Solution/>')
    t.eq(dir .. '/A.slnx', solution.find_target(dir))
  end },

  { 'walks up to the nearest thing to test', function()
    local dir = tmpdir()
    write(dir .. '/Shop.slnx', '<Solution/>')
    write(dir .. '/tests/Lib.Tests/Lib.Tests.csproj', '<Project/>')
    vim.fn.mkdir(dir .. '/tests/Lib.Tests/Pricing', 'p')
    t.eq(dir .. '/tests/Lib.Tests/Lib.Tests.csproj',
      solution.find_upward(dir .. '/tests/Lib.Tests/Pricing'))
    t.eq(dir .. '/Shop.slnx', solution.find_upward(dir .. '/tests'))
    t.eq(nil, solution.find_upward('/'))
  end },

  { 'reports a directory with nothing to test', function()
    local target, err = solution.find_target(tmpdir())
    t.eq(nil, target)
    t.matches('no solution or project file', err)
  end },

  { 'reads the test names out of --list-tests output', function()
    local out = table.concat({
      'Test run for /a/b/Shop.Tests.dll (.NETCoreApp,Version=v10.0)',
      'The following Tests are available:',
      '    Ns.ClassTests.A',
      '    Ns.ClassTests.B(n: 1)',
      '',
      'Some trailing line',
    }, '\n')
    t.eq({ 'Ns.ClassTests.A', 'Ns.ClassTests.B(n: 1)' }, run.parse_list(out))
  end },

  { 'parses the console logger result lines', function()
    t.eq({ name = 'Ns.C.M', outcome = 'passed', duration = 0.012 },
      run.parse_result_line('  Passed Ns.C.M [12 ms]'))
    t.eq({ name = 'Ns.C.M(n: 1)', outcome = 'failed', duration = 0.001 },
      run.parse_result_line('  Failed Ns.C.M(n: 1) [< 1 ms]'))
    t.eq({ name = 'Ns.C.M', outcome = 'skipped', duration = 62 },
      run.parse_result_line('  Skipped Ns.C.M [1 m 2 s]'))
    t.eq(nil, run.parse_result_line('Total tests: 16'))
    t.eq(nil, run.parse_result_line('  Passed! - Failed: 0'))
  end },

  { 'reads a trx file', function()
    local results = trx.parse(t.trx({
      { name = 'Ns.C.Passes', outcome = 'Passed', duration = '00:00:01.5000000' },
      { name = 'Ns.C.Skips', outcome = 'NotExecuted' },
      { name = 'Ns.C.Fails(s: &quot;x&quot;)', outcome = 'Failed',
        message = 'Assert.Equal() Failure', stack = '   at Ns.C.Fails() in /a/C.cs:line 12' },
    }))
    t.eq(3, #results)
    t.eq('passed', results[1].outcome)
    t.eq(1.5, results[1].duration)
    t.eq('skipped', results[2].outcome)
    t.eq('Ns.C.Fails(s: "x")', results[3].name)
    t.eq({ file = '/a/C.cs', line = 12 }, trx.failure_location(results[3]))
  end },

  { 'has no failure location without a stack trace', function()
    t.eq(nil, trx.failure_location({ outcome = 'failed' }))
    t.eq(nil, trx.failure_location({ outcome = 'failed', stack_trace = 'no position here' }))
  end },

  { 'escapes filter expressions', function()
    t.eq('FullyQualifiedName=Ns.C.M', filter.exact('Ns.C.M'))
    t.eq('FullyQualifiedName=Ns.C.M\\(n\\)', filter.exact('Ns.C.M(n)'))
    t.eq('FullyQualifiedName~Ns.C.', filter.prefix('Ns.C.'))
    t.eq('a|b', filter.join({ 'a', 'b' }))
  end },

  { 'formats durations the way vitest does', function()
    t.eq('0.032s', util.duration(0.032))
    t.eq('1.5s', util.duration(1.5))
    t.eq('35s', util.duration(35))
    t.eq('2m34s', util.duration(154))
    t.eq('1h02m', util.duration(3720))
  end },

  { 'splits process output into whole lines', function()
    local got = {}
    local feed = util.line_splitter(function(line) got[#got + 1] = line end)
    feed('one\ntw')
    t.eq({ 'one' }, got)
    feed('o\r\nthree')
    t.eq({ 'one', 'two' }, got)
    feed(nil)
    t.eq({ 'one', 'two', 'three' }, got)
  end },

  { 'finds a test declaration in the sources', function()
    local dir = tmpdir()
    write(dir .. '/obj/Generated.cs', 'class MoneyTests { public void Adds() {} }')
    write(dir .. '/Pricing/MoneyTests.cs', table.concat({
      'namespace Shop.Pricing;',
      '',
      'public class MoneyTests',
      '{',
      '    [Fact]',
      '    public void Adds() { }',
      '}',
    }, '\n'))
    local source = require('dtest.dotnet.source')
    t.eq({ file = dir .. '/Pricing/MoneyTests.cs', line = 3 },
      source.locate(dir, 'Shop.Pricing.MoneyTests', ''))
    t.eq({ file = dir .. '/Pricing/MoneyTests.cs', line = 6 },
      source.locate(dir, 'Shop.Pricing.MoneyTests', 'Adds'))
    t.eq(nil, source.locate(dir, 'Shop.Pricing.NoSuchTests', ''))
  end },

  { 'reads a source position out of a log line', function()
    local source = require('dtest.dotnet.source')
    t.eq(12, source.location_in_line('   at Ns.C.M() in /a/C.cs:line 12').line)
    t.eq('/a/C.cs', source.location_in_line('   at Ns.C.M() in /a/C.cs:line 12').file)
    t.eq(7, source.location_in_line('[xUnit.net] /a/C.cs(7,0): at Ns.C.M()').line)
    t.eq(nil, source.location_in_line('nothing to see here'))
  end },
}
