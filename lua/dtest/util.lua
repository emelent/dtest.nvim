-- Small helpers shared by the rest of the plugin: pattern escaping, the
-- line splitter every streamed process needs, and the duration format the
-- tree and the footer both print.
local M = {}

--- Escapes the magic characters of a Lua pattern so s matches literally.
function M.escape(s)
  return (s:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%0'))
end

--- Returns a function that takes arbitrary chunks of process output and
--- calls fn once per complete line, holding the tail back until it ends.
--- Process callbacks arrive split at buffer boundaries, not line ones.
function M.line_splitter(fn)
  local rest = ''
  return function(chunk)
    if chunk == nil then -- end of stream: flush whatever is left
      if rest ~= '' then
        fn(rest)
        rest = ''
      end
      return
    end
    rest = rest .. chunk
    while true do
      local nl = rest:find('\n', 1, true)
      if not nl then break end
      fn((rest:sub(1, nl - 1):gsub('\r$', '')))
      rest = rest:sub(nl + 1)
    end
  end
end

--- Formats a test time compactly, as vitest does: 0.032s below a second,
--- 1.5s below ten, 35s below a minute, then 2m34s and 1h02m.
--- @param d number seconds
function M.duration(d)
  if d < 1 then
    return string.format('%.3fs', d)
  elseif d < 10 then
    return string.format('%.1fs', d)
  elseif d < 60 then
    return string.format('%ds', math.floor(d + 0.5))
  elseif d < 3600 then
    local r = math.floor(d + 0.5)
    return string.format('%dm%02ds', math.floor(r / 60), r % 60)
  end
  local r = math.floor(d / 60 + 0.5)
  return string.format('%dh%02dm', math.floor(r / 60), r % 60)
end

--- Counts things: "2 projects", "1 project".
function M.plural(n, thing)
  if n == 1 then
    return '1 ' .. thing
  end
  return string.format('%d %ss', n, thing)
end

--- The last non-empty line of text, for summarising a failed command.
function M.last_line(text)
  local last
  for line in (text or ''):gmatch('[^\n]+') do
    if line:match('%S') then last = line end
  end
  return last
end

--- Shortens a source path relative to the working directory.
function M.display_path(path)
  local cwd = vim.uv.cwd()
  if cwd and path:sub(1, #cwd + 1) == cwd .. '/' then
    return path:sub(#cwd + 2)
  end
  return path
end

return M
