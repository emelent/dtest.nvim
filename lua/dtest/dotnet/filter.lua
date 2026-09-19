-- VSTest --filter expressions.
local M = {}

-- The characters that are special in a filter expression; escaped so they
-- match literally.
local specials = { ['\\'] = true, ['('] = true, [')'] = true, ['&'] = true,
  ['|'] = true, ['='] = true, ['!'] = true, ['~'] = true }

local function escape(s)
  return (s:gsub('.', function(c)
    if specials[c] then return '\\' .. c end
    return c
  end))
end

M.escape = escape

--- A filter matching the test method with fully qualified name fqn, which
--- for a theory means every one of its rows.
function M.exact(fqn)
  return 'FullyQualifiedName=' .. escape(fqn)
end

--- A filter matching every test whose fully qualified name contains prefix;
--- callers pass "Ns.Class." to select a class.
function M.prefix(prefix)
  return 'FullyQualifiedName~' .. escape(prefix)
end

--- Combines filters so a test matching any of them is run.
function M.join(filters)
  return table.concat(filters, '|')
end

return M
