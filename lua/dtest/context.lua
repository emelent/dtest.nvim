-- Reading a source buffer well enough to say which tests it holds: the
-- classes it declares, and which of a class's tests the cursor is sitting
-- in. Only declarations are parsed, never expressions, and method names
-- are matched against the ones dotnet already listed, so a helper method
-- or a call cannot be mistaken for a test.
local util = require('dtest.util')

local M = {}

-- The declarations a test class can be.
local type_keywords = { 'class', 'record', 'struct', 'interface' }

local is_keyword = {}
for _, keyword in ipairs(type_keywords) do
  is_keyword[keyword] = true
end

-- Line comments are dropped before anything is matched, so a commented-out
-- declaration is not one.
local function strip(line)
  return (line:gsub('//.*$', ''))
end

--- Every class the lines declare, in order, each with the namespace in
--- front of it. Only modifiers and braces may come before the keyword,
--- which is what keeps a generic constraint ("where T : class") from
--- reading as a declaration.
--- @return table[] classes {name=, fqn=, line=}
function M.classes(lines)
  local out = {}
  local namespace = ''
  for i, raw in ipairs(lines) do
    local line = strip(raw)
    local ns = line:match('^%s*namespace%s+([%w_%.]+)')
    if ns then namespace = ns end
    for _, keyword in ipairs(type_keywords) do
      local name = line:match('^[%w_%s{}]*%f[%w]' .. keyword .. '%s+([%w_]+)')
      -- "record struct Money" names itself twice; the name is the second.
      if name and not is_keyword[name] then
        out[#out + 1] = {
          name = name,
          fqn = namespace ~= '' and (namespace .. '.' .. name) or name,
          line = i,
        }
        break
      end
    end
  end
  return out
end

--- The class the cursor is in: the last one declared at or above row, or
--- the first in the file when the cursor is above them all (in the usings,
--- say), or nil when the file declares none.
function M.class_at(lines, row)
  local classes = M.classes(lines)
  local found
  for _, class in ipairs(classes) do
    if class.line <= row then found = class end
  end
  return found or classes[1]
end

--- The test nearest the cursor: whichever of names is declared on the
--- closest line at or above row. An attribute line belongs to the
--- declaration under it, so a cursor on `[Fact]` looks downwards first.
--- Nil means the cursor is above the first test of its class.
--- @param names table a set of method names, as listed by dotnet
function M.method_at(lines, row, names)
  local start = math.max(1, math.min(row, #lines))
  while start < #lines and lines[start]:match('^%s*%[') do
    start = start + 1
  end
  for i = start, 1, -1 do
    local line = strip(lines[i])
    local best, at
    for name in pairs(names) do
      -- Only a declaration counts: a return type and modifiers come before
      -- the name, where a call has either nothing or an expression, which
      -- brings characters these may not. Otherwise one test calling
      -- another would answer for it.
      local prefix = line:match('^(%s*[%w_%s%[%]<>,%.]-)%f[%w]' .. util.escape(name) .. '%s*[(<]')
      if prefix and prefix:find('%w') then
        -- The declaration's own name comes first on its line.
        local pos = #prefix
        if not at or pos < at then best, at = name, pos end
      end
    end
    if best then return best end
  end
  return nil
end

return M
