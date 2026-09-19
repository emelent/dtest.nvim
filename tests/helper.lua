-- Assertions and the dotnet stand-in every test runs against. Nothing here
-- shells out: dotnet's side of the conversation is played back from
-- canned output, so the tests are fast and work without the SDK.
local M = {}

function M.eq(want, got, what)
  if not vim.deep_equal(want, got) then
    error(string.format('%s\n  want: %s\n  got:  %s',
      what or 'not equal', vim.inspect(want), vim.inspect(got)), 2)
  end
end

function M.ok(value, what)
  if not value then error(what or 'expected a truthy value', 2) end
end

function M.matches(pattern, text, what)
  if type(text) ~= 'string' or not text:find(pattern) then
    error(string.format('%s\n  pattern: %s\n  text:    %s',
      what or 'no match', pattern, vim.inspect(text)), 2)
  end
end

--- The line of buffer lines that contains pattern, or nil.
function M.find_line(lines, pattern)
  for i, l in ipairs(lines) do
    if l:find(pattern) then return l, i end
  end
  return nil
end

function M.lines(name)
  local buf = vim.fn.bufnr(require('dtest.ui').buffer_names[name])
  if buf == -1 then return {} end
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

-- The fake dotnet.

local run = require('dtest.dotnet.run')
local real_system = run.system

--- Replaces the dotnet command runner for the length of one test. The
--- script is a table of handlers keyed by verb ('build', 'list', 'test'),
--- each returning {lines=…, code=…, trx=…}; the TRX text is written into
--- the run's results directory, the way dotnet would.
function M.stub_dotnet(script)
  run.system = function(cmd, opts, on_exit)
    local verb = cmd[2]
    local is_list = vim.tbl_contains(cmd, '--list-tests')
    local key = verb == 'build' and 'build' or (is_list and 'list' or 'test')
    local handler = script[key]
    local reply = type(handler) == 'function' and handler(cmd) or handler or {}
    for _, line in ipairs(reply.lines or {}) do
      if opts.stdout then opts.stdout(nil, line .. '\n') end
    end
    if reply.trx then
      local dir = cmd[vim.fn.index(cmd, '--results-directory') + 2]
      local fd = io.open(vim.fs.joinpath(dir, 'results.trx'), 'w')
      fd:write(reply.trx)
      fd:close()
    end
    vim.schedule(function() on_exit({ code = reply.code or 0 }) end)
    return { kill = function() end }
  end
end

function M.restore_dotnet()
  run.system = real_system
end

--- Runs fn once the predicate holds, or fails after a second.
function M.wait(predicate, what)
  local ok = vim.wait(3000, predicate, 10)
  if not ok then error('timed out waiting for ' .. (what or 'a condition'), 2) end
end

--- A .trx document holding the given results; each is
--- {name=, outcome=, duration=, message=, stack=}.
function M.trx(results)
  local parts = { '<?xml version="1.0" encoding="utf-8"?>\n<TestRun><Results>' }
  for _, r in ipairs(results) do
    local body = ''
    if r.message or r.stack then
      body = string.format('<Output><ErrorInfo><Message>%s</Message><StackTrace>%s</StackTrace></ErrorInfo></Output>',
        r.message or '', r.stack or '')
    end
    parts[#parts + 1] = string.format(
      '<UnitTestResult testName="%s" outcome="%s" duration="%s">%s</UnitTestResult>',
      (r.name:gsub('"', '&quot;')), r.outcome, r.duration or '00:00:00.0010000', body)
  end
  parts[#parts + 1] = '</Results></TestRun>'
  return table.concat(parts)
end

return M
