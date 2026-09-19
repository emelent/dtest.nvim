-- Finding where a test is declared, for jumping to it from the tree. The
-- sources are scanned rather than asked of a language server, so this works
-- before any LSP client has attached and on projects that have none.
local util = require('dtest.util')
local M = {}

local source_exts = { ['.cs'] = true, ['.fs'] = true, ['.vb'] = true }
local skip_dirs = { bin = true, obj = true, node_modules = true, ['.git'] = true }
local decl_keywords = { 'class', 'record', 'struct', 'interface', 'type', 'module' }

--- Reduces "Ns.Outer+Inner`1" to "Inner": the innermost simple name, which
--- is what the source actually declares.
function M.simple_class_name(class)
  local i = class:find('[%.%+][^%.%+]*$')
  if i then class = class:sub(i + 1) end
  local j = class:find('[`<]')
  if j then class = class:sub(1, j - 1) end
  return class
end

local function source_files(dir, out)
  local fd = vim.uv.fs_scandir(dir)
  if not fd then return out end
  while true do
    local name, kind = vim.uv.fs_scandir_next(fd)
    if not name then break end
    local path = vim.fs.joinpath(dir, name)
    if kind == 'directory' then
      if not skip_dirs[name] and name:sub(1, 1) ~= '.' then
        source_files(path, out)
      end
    elseif source_exts[(name:match('(%.[^%.]+)$') or ''):lower()] then
      out[#out + 1] = path
    end
  end
  return out
end

--- Finds the declaration of a test in the sources under dir: the line of
--- the method when method is given, otherwise the line of the class.
--- @return table|nil location {file=, line=}
function M.locate(dir, class, method)
  local simple = M.simple_class_name(class or '')
  if simple == '' then return nil end
  local class_pats = {}
  for _, kw in ipairs(decl_keywords) do
    class_pats[#class_pats + 1] = '%f[%w]' .. kw .. '%s+' .. util.escape(simple) .. '%f[%W]'
  end
  local method_pat = method ~= '' and method ~= nil
    and ('%f[%w]' .. util.escape(method) .. '%s*[(<]') or nil

  local function matches_class(s)
    for _, pat in ipairs(class_pats) do
      if s:find(pat) then return true end
    end
    return false
  end

  local fallback -- a partial class may declare the type without the method
  for _, path in ipairs(source_files(dir, {})) do
    local fd = io.open(path, 'r')
    if fd then
      local data = fd:read('*a')
      fd:close()
      if matches_class(data) then
        local class_line, method_line, n = 0, 0, 0
        for line in (data .. '\n'):gmatch('([^\n]*)\n') do
          n = n + 1
          if class_line == 0 and matches_class(line) then class_line = n end
          if method_pat and method_line == 0 and class_line > 0 and line:find(method_pat) then
            method_line = n
            break
          end
        end
        if not method_pat and class_line > 0 then
          return { file = path, line = class_line }
        end
        if method_line > 0 then
          return { file = path, line = method_line }
        end
        if not fallback and class_line > 0 then
          fallback = { file = path, line = class_line }
        end
      end
    end
  end
  return fallback
end

--- Extracts a file and line from a log line: .NET stack frames
--- ("at X in /path/file.cs:line 12"), xUnit's own frames
--- ("/path/file.cs(12,0): at X") and the log's own location lines
--- ("❯ path:12").
--- @return table|nil location {file=, line=}
function M.location_in_line(line)
  line = line:gsub('%s+$', '')
  local file, n = line:match(' in (.-):line (%d+)')
  if not file then file, n = line:match('❯ (%S+):(%d+)$') end
  if not file then file, n = line:match('(%S-%.%w+)%((%d+),%d+%)') end
  if not file then return nil end
  return { file = vim.fn.fnamemodify(file, ':p'), line = tonumber(n) }
end

return M
