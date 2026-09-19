-- The node model: solution root → project → class → method → case. The
-- root is a real node standing for the solution file, so node:project()
-- returns nil for it and callers must handle that. Status, counts and
-- duration roll up from the leaves.
local filter = require('dtest.dotnet.filter')

local M = {}

-- The levels of the tree, in order; a node is a runnable unit with its own
-- result from 'method' down.
M.RANK = { root = 0, project = 1, class = 2, method = 3, case = 4 }

local Node = {}
Node.__index = Node
M.Node = Node

local function new_node(fields)
  return setmetatable(fields, Node)
end

--- Reports whether the node is a runnable unit with its own result: a case,
--- or a method without cases.
function Node:is_leaf()
  return #self.children == 0 and M.RANK[self.kind] >= M.RANK.method
end

--- The project node the node belongs to, or nil for the root, which spans
--- them all.
function Node:project()
  local n = self
  while n do
    if n.kind == 'project' then return n end
    n = n.parent
  end
  return nil
end

--- The number of ancestors of the node.
function Node:depth()
  local d, p = 0, self.parent
  while p do
    d, p = d + 1, p.parent
  end
  return d
end

--- Every leaf under (or at) the node, in tree order.
function Node:leaves(out)
  out = out or {}
  if self:is_leaf() then
    out[#out + 1] = self
    return out
  end
  for _, c in ipairs(self.children) do c:leaves(out) end
  return out
end

--- Sets a leaf's status. It is ignored on interior nodes, which derive
--- theirs from below.
function Node:set_status(s)
  if self:is_leaf() then self._status = s end
end

--- Tallies the leaves under the node.
function Node:counts()
  local c = { total = 0, running = 0, queued = 0, passed = 0, failed = 0, skipped = 0 }
  for _, l in ipairs(self:leaves()) do
    c.total = c.total + 1
    local s = l._status
    if s and c[s] then c[s] = c[s] + 1 end
  end
  return c
end

--- The leaf's own status or, for an interior node, the roll-up of its
--- leaves: running beats queued beats failed beats passed beats skipped; a
--- node whose leaves have never run has no status at all.
function Node:status()
  if self:is_leaf() then return self._status end
  local c = self:counts()
  if c.running > 0 then return 'running' end
  if c.queued > 0 then return 'queued' end
  if c.failed > 0 then return 'failed' end
  if c.passed > 0 then return 'passed' end
  if c.skipped > 0 then return 'skipped' end
  return nil
end

--- How long the node's tests took in their latest run: a leaf's own time,
--- or the sum over the leaves beneath that have a result. Tests that have
--- not run contribute nothing.
function Node:duration()
  local total = 0
  for _, l in ipairs(self:leaves()) do
    if l.result then total = total + l.result.duration end
  end
  return total
end

--- Opens or closes every group under (and including) the node. A leaf has
--- nothing to open, so it is left alone.
function Node:set_expanded(expanded)
  for _, n in ipairs(M.collect(self)) do
    if not n:is_leaf() then n.expanded = expanded end
  end
end

--- The dotnet --filter expression selecting the node's tests; empty for a
--- project, which runs unfiltered. A case shares its method's filter, since
--- data rows cannot be addressed by fully qualified name.
function Node:filter()
  if self.kind == 'class' then return filter.prefix(self.fqn .. '.') end
  if self.kind == 'method' then return filter.exact(self.fqn) end
  if self.kind == 'case' then return self.parent:filter() end
  return ''
end

--- The fully qualified class name and method name that declare the node's
--- tests, for locating them in source. Both are empty for a project.
function Node:class_and_method()
  if self.kind == 'class' then return self.fqn, '' end
  if self.kind == 'method' then return self.parent.fqn, self.name end
  if self.kind == 'case' then return self.parent.parent.fqn, self.parent.name end
  return '', ''
end

--- "Project › Class › Method(args)", for a log header. The root is left
--- out: it is above every test, so naming it says nothing.
function Node:breadcrumb()
  local parts = {}
  local n = self
  while n and n.kind ~= 'root' do
    table.insert(parts, 1, n.name)
    n = n.parent
  end
  if #parts == 0 then return self.name end
  return table.concat(parts, ' › ')
end

--- Reports whether the node lies under ancestor.
function Node:is_under(ancestor)
  local p = self.parent
  while p do
    if p == ancestor then return true end
    p = p.parent
  end
  return false
end

-- Splitting the display names --list-tests prints.

-- The index of the first c outside angle brackets.
local function index_top_level(s, c)
  local depth = 0
  for i = 1, #s do
    local ch = s:sub(i, i)
    if ch == '<' then
      depth = depth + 1
    elseif ch == '>' then
      depth = depth - 1
    elseif ch == c and depth == 0 then
      return i
    end
  end
  return nil
end

-- Splits s at its last top-level dot; dots inside brackets do not count.
local function split_last(s)
  local depth = 0
  for i = #s, 1, -1 do
    local ch = s:sub(i, i)
    if ch == ')' or ch == '>' or ch == ']' then
      depth = depth + 1
    elseif ch == '(' or ch == '<' or ch == '[' then
      depth = depth - 1
    elseif ch == '.' and depth == 0 then
      return s:sub(1, i - 1), s:sub(i + 1)
    end
  end
  return '', s
end

--- Breaks a display name such as "Ns.Sub.Class.Method(n: 1)" into its
--- namespace, class, method and argument list ("(n: 1)"; empty for a plain
--- test). Dots inside parentheses or angle brackets do not split, so generic
--- and parameterised names hold together.
function M.split_name(name)
  local base, args = name, ''
  local i = index_top_level(name, '(')
  if i then
    base, args = name:sub(1, i - 1), name:sub(i)
  end
  local head, method = split_last(base)
  local ns, class = split_last(head)
  return ns, class, method, args
end

local function join(a, b)
  if a == '' then return b end
  return a .. '.' .. b
end

-- Drops the project name from the front of a class's fully qualified name
-- ("Shop.Core.Tests.Pricing.MoneyTests" in project Shop.Core.Tests becomes
-- "Pricing.MoneyTests").
local function short_class(project, fqn)
  local rest = fqn:match('^' .. vim.pesc(project) .. '%.(.+)$')
  return rest or fqn
end

-- Returns parent's child with the given kind and fqn, inserting it in name
-- order when it is missing.
local function child(parent, kind, name, fqn)
  for _, c in ipairs(parent.children) do
    if c.kind == kind and c.fqn == fqn then return c end
  end
  local n = new_node({ kind = kind, name = name, fqn = fqn, parent = parent, children = {}, expanded = false })
  local i = #parent.children + 1
  for k, c in ipairs(parent.children) do
    if c.name:lower() > name:lower() then
      i = k
      break
    end
  end
  table.insert(parent.children, i, n)
  return n
end

local Tree = {}
Tree.__index = Tree
M.Tree = Tree

--- An empty tree whose root stands for the solution (or the lone project)
--- at path, named name.
function M.new(name, path)
  return setmetatable({
    root = new_node({ kind = 'root', name = name, fqn = name, path = path, children = {}, expanded = true }),
    projects = {},
    _leaves = {}, -- by project node, then display name
  }, Tree)
end

--- Adds a project node for the project file at path, collapsed so a fresh
--- tree reads as a list of projects, or returns the existing one.
function Tree:add_project(path)
  for _, p in ipairs(self.projects) do
    if p.path == path then return p end
  end
  local name = vim.fn.fnamemodify(path, ':t:r')
  local p = new_node({ kind = 'project', name = name, fqn = name, path = path,
    parent = self.root, children = {}, expanded = false })
  table.insert(self.root.children, p)
  table.insert(self.projects, p)
  self._leaves[p] = {}
  return p
end

--- The leaf for the test with this display name under project, creating the
--- path to it when it is new (a test that appeared since the tree was
--- listed).
function Tree:leaf(project, name)
  local known = self._leaves[project][name]
  if known then return known end
  local ns, class, method, args = M.split_name(name)
  local class_fqn = join(ns, class)
  local class_node = child(project, 'class', short_class(project.name, class_fqn), class_fqn)
  local method_node = child(class_node, 'method', method, join(class_fqn, method))
  local leaf = method_node
  if args ~= '' then
    -- A method that previously stood alone becomes the parent of its rows.
    method_node._status, method_node.result = nil, nil
    leaf = child(method_node, 'case', args, name)
  end
  self._leaves[project][name] = leaf
  return leaf
end

--- The leaf to record a result on, for a run of target. A project's run
--- keeps its results under that project. The root's run covers the whole
--- solution, so each result goes to whichever project listed that test; one
--- that was listed nowhere is filed under the project whose name its own
--- prefixes, since that is how test names are namespaced.
function Tree:leaf_in(target, name)
  if target.kind == 'project' then return self:leaf(target, name) end
  for _, p in ipairs(self.projects) do
    local known = self._leaves[p][name]
    if known then return known end
  end
  local best
  for _, p in ipairs(self.projects) do
    if name:sub(1, #p.name + 1) == p.name .. '.' and (not best or #p.name > #best.name) then
      best = p
    end
  end
  best = best or self.projects[1]
  if not best then return nil end
  return self:leaf(best, name)
end

local function collect(n, out)
  out = out or {}
  out[#out + 1] = n
  for _, c in ipairs(n.children) do collect(c, out) end
  return out
end

M.collect = collect

--- Replaces the tests under project with names (display names from
--- --list-tests). Results and expansion of nodes that still exist are kept.
--- New classes start collapsed, so a fresh project reads as a list of them.
function Tree:set_tests(project, names)
  local old = {}
  for _, n in ipairs(collect(project)) do
    old[n.kind .. '\0' .. n.fqn] = n
  end
  project.children = {}
  self._leaves[project] = {}
  for _, name in ipairs(names) do
    self:leaf(project, name)
  end
  for _, n in ipairs(collect(project)) do
    local prev = old[n.kind .. '\0' .. n.fqn]
    if prev then
      n.expanded = prev.expanded
      if n:is_leaf() and prev:is_leaf() then
        n._status, n.result = prev._status, prev.result
      end
    end
  end
end

--- The deepest node that holds every one of nodes, or nil when they do
--- not all belong to the same tree.
function M.common_ancestor(nodes)
  if #nodes == 0 then return nil end
  -- Every ancestor of the first node, itself included; the answer is one
  -- of them, and the shallowest each of the others reaches.
  local chain, node = {}, nodes[1]
  while node do
    chain[node] = true
    node = node.parent
  end
  local shared = nodes[1]
  for i = 2, #nodes do
    local other = nodes[i]
    while other and not chain[other] do
      other = other.parent
    end
    if not other then return nil end
    if other:depth() < shared:depth() then shared = other end
  end
  return shared
end

--- Flattens the tree into the rows to draw, from the node the view is
--- rooted at. Without a filter, collapsed nodes hide their children. With a
--- query, only leaves whose display name (or project name) contains it,
--- case-insensitively, are shown; with a status, only leaves in that
--- status. Matching leaves bring their ancestors along regardless of
--- expansion, and projects without a match are left out.
function Tree:visible_from(from, query, status)
  if not from or #self.projects == 0 then return {} end
  local q = (query or ''):lower()
  if q == '' and not status then
    local rows = {}
    local function walk(n)
      rows[#rows + 1] = n
      if n.expanded then
        for _, c in ipairs(n.children) do walk(c) end
      end
    end
    walk(from)
    return rows
  end
  local rows = {}
  local function walk(n)
    if n:is_leaf() then
      local by_name = q == ''
        or n.fqn:lower():find(q, 1, true) ~= nil
        or (n:project() and n:project().name:lower():find(q, 1, true) ~= nil)
      local by_status = status == nil or n._status == status
      if by_name and by_status then rows[#rows + 1] = n end
      return
    end
    local start = #rows
    rows[#rows + 1] = n
    for _, c in ipairs(n.children) do walk(c) end
    if #rows == start + 1 then
      rows[#rows] = nil -- nothing matched beneath: drop the node itself
    end
  end
  walk(from)
  return rows
end

--- Expands the interior nodes under target that hold a failure and
--- collapses the rest, so a finished run reads like a report: passing
--- classes take one line, failing ones show their tests. A project is only
--- ever opened, never folded shut, so a run cannot close the part of the
--- tree that is being read; the root always stays open.
function Tree:fold_by_result(target)
  for _, n in ipairs(collect(target)) do
    if n.kind == 'root' or n:is_leaf() then -- left alone
    elseif n.kind == 'project' then
      n.expanded = n.expanded or n:counts().failed > 0
    else
      n.expanded = n:counts().failed > 0
    end
  end
end

--- Opens or closes every interior node at once, projects included.
function Tree:set_expanded(expanded)
  self.root:set_expanded(expanded)
end

--- Every leaf of the tree, in order.
function Tree:leaves()
  return self.root:leaves()
end

--- Tallies every leaf in the tree.
function Tree:counts()
  return self.root:counts()
end

return M
