-- Reading a source buffer: which classes it declares, and which test the
-- cursor is in.
local t = require('tests.helper')
local context = require('dtest.context')

local source = {
  'using Xunit;',                          -- 1
  '',                                      -- 2
  'namespace Shop.Api.Tests.Middleware;',  -- 3
  '',                                      -- 4
  '// class Commented { }',                -- 5
  'public sealed partial class RateLimitMiddlewareTests : IDisposable', -- 6
  '{',                                     -- 7
  '    [Fact]',                            -- 8
  '    public void UnderLimit_Passes()',   -- 9
  '    {',                                 -- 10
  '        Assert.True(Helper(99));',      -- 11
  '    }',                                 -- 12
  '',                                      -- 13
  '    [Theory]',                          -- 14
  '    [InlineData(429)]',                 -- 15
  '    public async Task OverLimit_Returns429(int code)', -- 16
  '    {',                                 -- 17
  '        UnderLimit_Passes();',          -- 18
  '    }',                                 -- 19
  '',                                      -- 20
  '    private bool Helper<T>(T n) => true;', -- 21
  '}',                                     -- 22
}

local names = { UnderLimit_Passes = true, OverLimit_Returns429 = true }

return {
  { 'finds the classes a file declares, with their namespace', function()
    t.eq({ { name = 'RateLimitMiddlewareTests',
             fqn = 'Shop.Api.Tests.Middleware.RateLimitMiddlewareTests', line = 6 } },
      context.classes(source))
  end },

  { 'takes a block namespace and several classes in one file', function()
    local lines = {
      'namespace Shop.Core.Tests',
      '{',
      '    public class MoneyTests { }',
      '    internal record struct Helper { }',
      '}',
      'namespace Other { public class PingTests { } }',
    }
    local classes = context.classes(lines)
    t.eq(3, #classes)
    t.eq('Shop.Core.Tests.MoneyTests', classes[1].fqn)
    t.eq('Shop.Core.Tests.Helper', classes[2].fqn, 'record struct names itself twice')
    t.eq('Other.PingTests', classes[3].fqn, 'a namespace and a class on one line')
  end },

  { 'is not fooled by a comment or a generic constraint', function()
    t.eq({}, context.classes({
      '// public class Commented { }',
      'public T Make<T>() where T : class, new() => default;',
      'var x = myclass;',
    }))
  end },

  { 'names the class the cursor is in', function()
    t.eq('RateLimitMiddlewareTests', context.class_at(source, 18).name)
    -- Above every declaration, the file's first class is the one meant.
    t.eq('RateLimitMiddlewareTests', context.class_at(source, 1).name)
    t.eq(nil, context.class_at({ 'using Xunit;' }, 1))
  end },

  { 'finds the test at or above the cursor', function()
    t.eq('UnderLimit_Passes', context.method_at(source, 9, names))
    t.eq('UnderLimit_Passes', context.method_at(source, 11, names), 'inside the body')
    t.eq('OverLimit_Returns429', context.method_at(source, 17, names))
    -- A call to another test does not move the answer.
    t.eq('OverLimit_Returns429', context.method_at(source, 18, names))
    -- Nor does a helper that was never listed.
    t.eq('OverLimit_Returns429', context.method_at(source, 21, names))
  end },

  { 'reads an attribute as part of the test below it', function()
    t.eq('UnderLimit_Passes', context.method_at(source, 8, names))
    t.eq('OverLimit_Returns429', context.method_at(source, 14, names))
    t.eq('OverLimit_Returns429', context.method_at(source, 15, names))
  end },

  { 'has no test above the first one', function()
    t.eq(nil, context.method_at(source, 7, names))
    t.eq(nil, context.method_at(source, 1, names))
  end },
}
