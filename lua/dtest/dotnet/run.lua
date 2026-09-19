-- Driving the dotnet CLI: building, listing tests and running them while
-- results stream back. Every call is asynchronous and reports through
-- callbacks that are safe to touch buffers from.
local util = require('dtest.util')
local trx = require('dtest.dotnet.trx')

local M = {}

--- The dotnet arguments common to every invocation.
--- @param opts table {configuration=, no_build=}
local function common_args(opts)
  local args = {}
  if opts.configuration and opts.configuration ~= '' then
    args[#args + 1] = '-c'
    args[#args + 1] = opts.configuration
  end
  if opts.no_build then args[#args + 1] = '--no-build' end
  return args
end

-- The command runner, so the tests can stand in for dotnet.
M.system = function(cmd, sysopts, on_exit)
  return vim.system(cmd, sysopts, on_exit)
end

--- Spawns dotnet, feeding every line of its output to on_line and calling
--- on_exit with the exit code once it has all been read.
local function spawn(cmd, on_line, on_exit)
  local feed = util.line_splitter(on_line)
  local pump = vim.schedule_wrap(function(_, chunk)
    feed(chunk)
  end)
  return M.system(cmd, { text = true, stdout = pump, stderr = pump }, vim.schedule_wrap(function(res)
    feed(nil)
    on_exit(res)
  end))
end

--- Builds path (a solution or project), streaming its output.
--- @param handlers table {on_line=, on_done=function(err)}
function M.build(path, opts, handlers)
  local cmd = { 'dotnet', 'build', path, '--nologo', '-v', 'minimal' }
  if opts.configuration and opts.configuration ~= '' then
    vim.list_extend(cmd, { '-c', opts.configuration })
  end
  handlers.on_line('$ ' .. table.concat(cmd, ' '))
  return spawn(cmd, handlers.on_line, function(res)
    handlers.on_done(res.code ~= 0 and 'dotnet build failed' or nil)
  end)
end

-- The header that precedes the test names in --list-tests output.
local list_header = 'The following Tests are available:'

--- Extracts test names from --list-tests output: the indented lines that
--- follow the header, up to the next line that is not indented.
function M.parse_list(out)
  local names, inside = {}, false
  for line in (out .. '\n'):gmatch('([^\n]*)\n') do
    line = line:gsub('\r$', '')
    if line:sub(1, #list_header) == list_header then
      inside = true
    elseif not inside then -- still before the header
    elseif not line:match('%S') then -- a blank line does not end the list
    elseif line:sub(1, 1) == ' ' or line:sub(1, 1) == '\t' then
      names[#names + 1] = vim.trim(line)
    else
      inside = false
    end
  end
  return names
end

--- Lists the tests of one project.
--- @param handlers table {on_done=function(names, err)}
function M.list(project, opts, handlers)
  local cmd = { 'dotnet', 'test', project, '--list-tests', '--nologo' }
  vim.list_extend(cmd, common_args(opts))
  local lines = {}
  return spawn(cmd, function(line) lines[#lines + 1] = line end, function(res)
    local out = table.concat(lines, '\n')
    if res.code ~= 0 then
      handlers.on_done(nil, util.last_line(out) or ('dotnet test --list-tests exited ' .. res.code))
      return
    end
    handlers.on_done(M.parse_list(out))
  end)
end

--- Reads the durations the console logger prints: "12 ms", "< 1 ms",
--- "1 s" or "1 m 2 s". Anything unreadable is zero. Seconds.
function M.parse_console_duration(s)
  local units = { ms = 0.001, s = 1, m = 60, h = 3600 }
  local fields = {}
  for f in (s or ''):gsub('<', ''):gmatch('%S+') do fields[#fields + 1] = f end
  local total = 0
  for i = 1, #fields - 1, 2 do
    local n = tonumber((fields[i]:gsub(',', '.')))
    local unit = units[fields[i + 1]]
    if not n or not unit then return 0 end
    total = total + n * unit
  end
  return total
end

--- Parses one console logger line into a result, or returns nil for any
--- other line. The logger prints "  Passed Ns.Class.Method(n: 1) [12 ms]".
function M.parse_result_line(line)
  local outcome, rest = line:match('^%s+(Passed)%s+(.+)$')
  if not outcome then outcome, rest = line:match('^%s+(Failed)%s+(.+)$') end
  if not outcome then outcome, rest = line:match('^%s+(Skipped)%s+(.+)$') end
  if not outcome then return nil end
  local name, duration = rest:match('^(.-)%s+%[([^%]]+)%]%s*$')
  if not name then
    name, duration = vim.trim(rest), ''
  end
  return {
    name = name,
    outcome = outcome:lower(),
    duration = M.parse_console_duration(duration),
  }
end

--- Reads every .trx file a run left in dir, which is one per project.
--- @return table[]|nil results, nil when the run wrote none
function M.read_results(dir)
  local files = vim.fn.glob(vim.fs.joinpath(dir, '*.trx'), true, true)
  if #files == 0 then return nil end
  local results = {}
  for _, path in ipairs(files) do
    vim.list_extend(results, trx.read(path) or {})
  end
  return results
end

--- Runs the tests of project that match filter (every test when filter is
--- empty). Results arrive twice over: from the console logger as they
--- happen, and in full from the TRX file when the run ends.
--- @param handlers table {on_line=, on_result=, on_done=function(results, err)}
--- @return table handle with a cancel method
function M.run(project, filter, opts, handlers)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local cmd = {
    'dotnet', 'test', project, '--nologo',
    '--logger', 'console;verbosity=normal',
    -- No LogFileName: a solution-wide run has one dotnet test per project,
    -- and they would all write over the same name. The default names are
    -- unique, so every file in the directory is read instead.
    '--logger', 'trx',
    '--results-directory', dir,
  }
  if filter and filter ~= '' then
    vim.list_extend(cmd, { '--filter', filter })
  end
  vim.list_extend(cmd, common_args(opts))
  handlers.on_line('$ ' .. table.concat(cmd, ' '))

  local cancelled = false
  local proc = spawn(cmd, function(line)
    handlers.on_line(line)
    local result = M.parse_result_line(line)
    if result then handlers.on_result(result) end
  end, function(res)
    local results = M.read_results(dir)
    vim.fn.delete(dir, 'rf')
    if cancelled then
      handlers.on_done(results, 'run cancelled')
    elseif not results and res.code ~= 0 then
      -- No results and a non-zero exit: the build or the test host failed.
      handlers.on_done(nil, 'dotnet test failed')
    else
      handlers.on_done(results or {})
    end
  end)

  return {
    cancel = function()
      cancelled = true
      -- SIGTERM rather than SIGKILL, so dotnet takes its test hosts with it.
      pcall(function() proc:kill(15) end)
    end,
  }
end

return M
