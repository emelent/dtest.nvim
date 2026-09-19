-- Reading the Visual Studio test results file (.trx) dotnet writes when a
-- run ends. It is the only place the failure messages, stack traces and
-- captured output come from; the console logger gives outcomes alone.
local M = {}

local entities = {
  ['&lt;'] = '<', ['&gt;'] = '>', ['&amp;'] = '&', ['&quot;'] = '"', ['&apos;'] = "'",
}

--- Decodes the XML entities a TRX attribute or element can carry.
function M.unescape(s)
  if not s then return nil end
  s = s:gsub('&#x(%x+);', function(h) return vim.fn.nr2char(tonumber(h, 16)) end)
  s = s:gsub('&#(%d+);', function(d) return vim.fn.nr2char(tonumber(d, 10)) end)
  -- &amp; last, so "&amp;lt;" does not decode twice.
  s = s:gsub('&%a+;', function(e) return entities[e] or e end)
  return s
end

-- The text of element name inside xml, unescaped; nil when it is absent.
local function element(xml, name)
  if not xml then return nil end
  local body = xml:match('<' .. name .. '>(.-)</' .. name .. '>')
  if not body then return nil end
  local cdata = body:match('^%s*<!%[CDATA%[(.-)%]%]>%s*$')
  return M.unescape(cdata or body)
end

--- Reads the "hh:mm:ss.fffffff" durations of a .trx file, in seconds.
function M.parse_duration(s)
  local h, m, sec = (s or ''):match('^(%d+):(%d+):([%d%.]+)$')
  if not h then return 0 end
  return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(sec)
end

local outcomes = {
  Passed = 'passed',
  Failed = 'failed', Error = 'failed', Timeout = 'failed', Aborted = 'failed',
  NotExecuted = 'skipped', Inconclusive = 'skipped', NotRunnable = 'skipped',
}

--- Maps a TRX outcome attribute onto one of passed, failed, skipped, or nil.
function M.outcome(s)
  return outcomes[s or '']
end

local function join_non_empty(a, b)
  local kept = {}
  for _, part in ipairs({ a, b }) do
    if part and part:match('%S') then kept[#kept + 1] = part end
  end
  return table.concat(kept, '\n')
end

--- Reads the per-test results out of a .trx document.
--- @return table[] results
function M.parse(text)
  local results = {}
  local pos = 1
  while true do
    local from = text:find('<UnitTestResult', pos, true)
    if not from then break end
    local open_end = text:find('>', from, true)
    if not open_end then break end
    local open = text:sub(from, open_end)
    local body = ''
    if open:sub(-2) == '/>' then
      pos = open_end + 1
    else
      local close = text:find('</UnitTestResult>', open_end, true)
      if not close then break end
      body = text:sub(open_end + 1, close - 1)
      pos = close + #'</UnitTestResult>'
    end
    local name = M.unescape(open:match('testName="(.-)"'))
    local outcome = M.outcome(open:match('outcome="(.-)"'))
    if name and outcome then
      local err = body:match('<ErrorInfo>(.-)</ErrorInfo>')
      results[#results + 1] = {
        name = name,
        outcome = outcome,
        duration = M.parse_duration(open:match('duration="(.-)"')),
        message = vim.trim(element(err, 'Message') or ''),
        stack_trace = (element(err, 'StackTrace') or ''):gsub('[\n ]+$', ''),
        output = join_non_empty(element(body, 'StdOut'), element(body, 'StdErr')):gsub('\n+$', ''),
      }
    end
  end
  return results
end

--- Parses the file at path. A missing file yields no results and no error,
--- since dotnet writes none when the run never started.
--- @return table[]|nil results
function M.read(path)
  local fd = io.open(path, 'r')
  if not fd then return nil end
  local data = fd:read('*a')
  fd:close()
  return M.parse(data)
end

--- The source position of the first stack frame that has one, in the
--- "at X in /path/file.cs:line N" form of .NET stack traces.
--- @return table|nil location {file=, line=}
function M.failure_location(result)
  if not result or (result.stack_trace or '') == '' then return nil end
  local file, line = result.stack_trace:match(' in (.-):line (%d+)')
  if not file then return nil end
  return { file = file, line = tonumber(line) }
end

return M
