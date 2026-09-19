-- The model behind the two panes: the tree, the queue of dotnet runs, the
-- batch the footer reports on, and the raw output of each run. It knows
-- nothing about windows; it calls on_change when something it holds has
-- moved, and the UI decides when to draw.
local config = require('dtest.config')
local dotnet_run = require('dtest.dotnet.run')
local solution = require('dtest.dotnet.solution')
local source = require('dtest.dotnet.source')
local tree = require('dtest.tree')
local trx = require('dtest.dotnet.trx')

local M = {}

local Session = {}
Session.__index = Session
M.Session = Session

-- The key the build's output is filed under, beside the project paths.
M.BUILD_LOG = 'build'

-- How long a message sits in the footer before it goes.
local message_timeout = 5000

-- How many `dotnet test --list-tests` run at once; each is a full dotnet
-- process, and a solution can have dozens of test projects.
local list_workers = 4

--- A session for the solution or project at target.
function M.new(target, opts)
  local name = vim.fn.fnamemodify(target, ':t:r')
  return setmetatable({
    target = target,
    name = name,
    opts = opts or {},
    tree = tree.new(name, target),
    logs = {},
    last_log = nil,
    queue = {},
    run = nil,
    loading = 0,
    pending = {}, -- projects still to list, when more than list_workers
    building = false,
    batch = {},
    batch_start = nil,
    batch_end = nil,
    batch_clock = nil,
    message = nil,
    message_id = 0,
    zoom = nil,
    query = '',
    status_filter = nil,
    show_output = false,
    locations = {},
    on_change = function() end,
  }, Session)
end

function Session:changed()
  self.on_change()
end

--- Reports whether dotnet is doing something on our behalf.
function Session:busy()
  return self.building or self.loading > 0 or self.run ~= nil
end

--- Shows text in the footer for a few seconds.
function Session:notify(text, is_error)
  self.message = { text = text, is_error = is_error or false }
  self.message_id = self.message_id + 1
  local id = self.message_id
  vim.defer_fn(function()
    if self.message_id == id then
      self.message = nil
      self:changed()
    end
  end, message_timeout)
  self:changed()
end

--- The dotnet options every invocation shares.
function Session:dotnet_opts()
  return { configuration = self.opts.configuration, no_build = self.opts.no_build }
end

-- Discovery, building and listing.

--- Finds the test projects and starts the build, or goes straight to
--- listing when builds are off.
function Session:start()
  local projects, err = solution.projects(self.target)
  if not projects then
    self:notify(err, true)
    return
  end
  for _, path in ipairs(projects) do
    self.tree:add_project(path)
  end
  self:changed()
  if self.opts.no_build or not config.options.build_on_open then
    self:list_all()
  else
    self:build()
  end
end

--- Rebuilds (unless builds are off) and lists the tests again.
function Session:reload()
  if self.building or self.loading > 0 then
    self:notify('Already loading', true)
    return
  end
  self.zoom = nil -- listing replaces the nodes it was pointing at
  if self.opts.no_build then
    self:list_all()
  else
    self:build()
  end
end

function Session:build()
  self.building = true
  self.logs[M.BUILD_LOG] = {}
  self.last_log = M.BUILD_LOG
  self:changed()
  dotnet_run.build(self.target, self:dotnet_opts(), {
    on_line = function(line)
      table.insert(self.logs[M.BUILD_LOG], line)
    end,
    on_done = function(err)
      self.building = false
      if err then
        self:notify(err .. ' (press ' .. config.key_for('toggle-output') .. ' for the output)', true)
      end
      self:list_all()
    end,
  })
end

--- Lists the tests of every project, a few at a time.
function Session:list_all()
  local opts = self:dotnet_opts()
  opts.no_build = true -- just built, or the user asked for no builds
  local queue = vim.list_slice(self.tree.projects)
  self.loading = #queue
  self:changed()
  local function next_project()
    local project = table.remove(queue, 1)
    if not project then return end
    dotnet_run.list(project.path, opts, {
      on_done = function(names, err)
        self.loading = self.loading - 1
        if err then
          self.logs[project.path] = self.logs[project.path] or {}
          table.insert(self.logs[project.path], err)
          self:notify(project.name .. ': ' .. err, true)
        else
          self.tree:set_tests(project, names)
        end
        self:changed()
        next_project()
      end,
    })
  end
  for _ = 1, math.min(list_workers, #queue) do
    next_project()
  end
end

-- Running.

--- The node the view is rooted at: the subtree in focus, or the solution
--- when there is none.
function Session:root()
  return self.zoom or self.tree.root
end

--- The rows the tree pane draws, within whatever is in focus.
function Session:rows()
  return self.tree:visible_from(self:root(), self.query, self.status_filter)
end

--- Reports whether the tree is narrowed by a query or a status, in which
--- case folding is off since matches are always shown.
function Session:filtered()
  return self.query ~= '' or self.status_filter ~= nil
end

--- Queues a run for each project the nodes belong to and starts the first
--- when nothing else is running.
function Session:enqueue(nodes)
  -- Nothing running means this starts a new batch, so the footer describes
  -- these runs and not the last ones.
  if not self.run then
    self.batch_start, self.batch_end, self.batch = vim.uv.hrtime(), nil, {}
    self.batch_clock = os.time() -- the wall clock the footer prints
  end
  -- The root is the solution, so running it is one `dotnet test` over the
  -- whole thing rather than one invocation per project.
  for _, n in ipairs(nodes) do
    if n.kind == 'root' then
      self:queue_run({ target = n, filter = '', label = n.name .. ' › all', leaves = n:leaves() })
      return self:pump()
    end
  end
  local by_project, order = {}, {}
  for _, n in ipairs(nodes) do
    local p = n:project()
    if p then
      if not by_project[p] then
        by_project[p] = {}
        order[#order + 1] = p
      end
      table.insert(by_project[p], n)
    end
  end
  for _, p in ipairs(order) do
    local filters, labels, leaves = {}, {}, {}
    local whole = false
    for _, n in ipairs(by_project[p]) do
      if n.kind == 'project' then
        whole = true
        break
      end
      vim.list_extend(leaves, n:leaves())
      filters[#filters + 1] = n:filter()
      labels[#labels + 1] = n.name
    end
    if whole then
      filters, labels, leaves = {}, { 'all' }, p:leaves()
    end
    self:queue_run({
      target = p,
      filter = require('dtest.dotnet.filter').join(filters),
      label = p.name .. ' › ' .. table.concat(labels, ', '),
      leaves = leaves,
    })
  end
  self:pump()
end

--- Adds a request to the queue and marks its tests as waiting. Ones
--- already running, from another request for the same tests, keep spinning.
function Session:queue_run(req)
  for _, l in ipairs(req.leaves) do
    if l:status() ~= 'running' then l:set_status('queued') end
  end
  self:add_to_batch(req.leaves)
  table.insert(self.queue, req)
end

--- Records leaves as part of the batch in progress. A project and one of
--- its classes can both be queued in the same batch, and a test that was
--- never listed shows up only when its result arrives, so the batch is a
--- set that either can add to.
function Session:add_to_batch(leaves)
  for _, l in ipairs(leaves) do
    self.batch[l] = true
  end
end

--- How long the batch has been going, and how long it took once it is
--- over, in seconds. It is wall-clock time rather than the sum of the
--- tests' own: a sum only moves when a result lands, so it sits still
--- through every slow test, and a timer that stops for seconds at a time
--- reads as a stuck program rather than a slow one.
function Session:batch_duration()
  if not self.batch_start then return 0 end
  local finish = self.batch_end or vim.uv.hrtime()
  return (finish - self.batch_start) / 1e9
end

--- Tallies the batch by the state its tests are in now. A test whose run
--- was cancelled or dropped has no state and falls out, so the rows always
--- add up to the total above them.
function Session:batch_counts()
  local c = { total = 0, running = 0, queued = 0, passed = 0, failed = 0, skipped = 0 }
  for leaf in pairs(self.batch) do
    local s = leaf:status()
    if s and c[s] then
      c[s] = c[s] + 1
      c.total = c.total + 1
    end
  end
  return c
end

--- Forgets the queued runs and clears their tests' queued marks.
function Session:drop_queue()
  for _, req in ipairs(self.queue) do
    for _, l in ipairs(req.leaves) do
      if l:status() == 'queued' then l:set_status(nil) end
    end
  end
  self.queue = {}
end

--- Starts the next queued run when none is active.
function Session:pump()
  if self.run or #self.queue == 0 then
    self:changed()
    return
  end
  local req = table.remove(self.queue, 1)
  for _, l in ipairs(req.leaves) do
    l:set_status('running')
  end
  local key = req.target.path
  self.logs[key] = {}
  self.last_log = key
  local handle
  handle = dotnet_run.run(req.target.path, req.filter, self:dotnet_opts(), {
    on_line = function(line)
      table.insert(self.logs[key], line)
    end,
    on_result = function(result)
      self:apply(req.target, result)
    end,
    on_done = function(results, err)
      self:finish(req, results, err)
    end,
  })
  self.run = { req = req, handle = handle }
  self:changed()
end

function Session:finish(req, results, err)
  for _, r in ipairs(results or {}) do
    self:apply(req.target, r)
  end
  for _, l in ipairs(req.leaves) do
    if l:status() == 'running' then l:set_status(nil) end
  end
  self.run = nil
  self.tree:fold_by_result(req.target)
  if err then
    self:drop_queue()
    self:notify(req.label .. ': ' .. err, true)
  end
  if #self.queue == 0 then
    self.batch_end = vim.uv.hrtime()
    -- Nothing is running or waiting any more, so nothing may still look
    -- like it is: a relist during a run leaves nodes behind that the run
    -- itself can no longer clear.
    for _, leaf in ipairs(self.tree:leaves()) do
      local s = leaf:status()
      if s == 'running' or s == 'queued' then leaf:set_status(nil) end
    end
  end
  self:pump()
  self:changed()
end

--- Records one result on its leaf, creating the leaf for a test that was
--- not listed. A solution-wide run reports tests from every project, so the
--- tree decides which one each belongs to.
function Session:apply(target, result)
  local leaf = self.tree:leaf_in(target, result.name)
  if not leaf then return end
  self.batch[leaf] = true -- it may not have been listed, so not queued either
  -- The console logger has no message or stack trace, so a line that
  -- arrives first must not wipe what the TRX file will bring.
  local previous = leaf.result
  if previous and previous.name == result.name and (result.message or '') == '' then
    result = vim.tbl_extend('keep', result, previous)
  end
  leaf.result = result
  leaf:set_status(result.outcome)
end

--- Re-runs every test that failed last time. Theory rows share their
--- method's filter, so each method is included once.
function Session:run_failed()
  local nodes, seen = {}, {}
  for _, l in ipairs(self:root():leaves()) do
    if l:status() == 'failed' then
      local unit = l.kind == 'case' and l.parent or l
      if not seen[unit] then
        seen[unit] = true
        nodes[#nodes + 1] = unit
      end
    end
  end
  if #nodes == 0 then
    self:notify('No failed tests to re-run', false)
    return
  end
  self:enqueue(nodes)
end

--- Stops the active run and drops the queue.
function Session:cancel()
  if not self.run then
    self:notify('Nothing is running', false)
    return
  end
  self:drop_queue()
  self.run.handle.cancel()
  self:notify('Cancelling ' .. self.run.req.label .. '…', false)
end

--- Kills whatever dotnet is doing; the UI calls it when the panes close.
function Session:shutdown()
  self.queue = {}
  if self.run then self.run.handle.cancel() end
end

-- Source positions.

--- The source position for a node: the project file for a project, the
--- class or method declaration otherwise, falling back to the failure
--- position from a stack trace.
--- @return table|nil location {file=, line=}
function Session:locate(node)
  if node.kind == 'root' or node.kind == 'project' then
    return { file = node.path, line = 0 }
  end
  local class, method = node:class_and_method()
  local key = class .. '#' .. method
  if self.locations[key] then return self.locations[key] end
  local loc = source.locate(vim.fs.dirname(node:project().path), class, method)
  if not loc and node.result then
    loc = trx.failure_location(node.result)
  end
  if loc then self.locations[key] = loc end
  return loc
end

--- The raw dotnet output to show for a node: the run it came from, which is
--- its own project's or, after a solution-wide run, the root's. A node no
--- run has covered falls back to whatever ran last, and then to the build.
--- @return string key, string name
function Session:output_for(node)
  local n = node
  while n do
    if n.path and self.logs[n.path] then return n.path, n.name end
    n = n.parent
  end
  if self.last_log and self.logs[self.last_log] then
    if self.last_log == self.tree.root.path then return self.last_log, self.tree.root.name end
    for _, p in ipairs(self.tree.projects) do
      if p.path == self.last_log then return p.path, p.name end
    end
  end
  return M.BUILD_LOG, 'build'
end

--- The next (or previous) failed test in tree order from node, wrapping
--- around.
function Session:next_failure(from, forward)
  local leaves = self:root():leaves()
  if #leaves == 0 then return nil end
  local start = 0
  if from then
    for i, l in ipairs(leaves) do
      if l == from or (not from:is_leaf() and l:is_under(from)) then
        start = i
        if forward then break end
      end
    end
  end
  for step = 1, #leaves do
    local i = forward and (start + step) or (start - step)
    i = ((i - 1) % #leaves + #leaves) % #leaves + 1
    if leaves[i]:status() == 'failed' then return leaves[i] end
  end
  return nil
end

return M
