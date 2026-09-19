-- Finding what to test: solution and project files, and which of a
-- solution's projects hold tests.
local M = {}

local project_exts = { ['.csproj'] = true, ['.fsproj'] = true, ['.vbproj'] = true }

local function ext(path)
  return (path:match('(%.[^%./\\]+)$') or ''):lower()
end

--- Reports whether path names a project file dotnet test accepts.
function M.is_project_file(path)
  return project_exts[ext(path)] == true
end

--- Reports whether path names a solution file (.sln or .slnx).
function M.is_solution_file(path)
  local e = ext(path)
  return e == '.sln' or e == '.slnx'
end

--- Picks what to open when no file is given: a solution file in dir,
--- otherwise the first project file, each in name order.
--- @return string|nil target, string|nil err
function M.find_target(dir)
  local solutions, projects = {}, {}
  for name, kind in vim.fs.dir(dir) do
    if kind == 'file' then
      if M.is_solution_file(name) then
        solutions[#solutions + 1] = name
      elseif M.is_project_file(name) then
        projects[#projects + 1] = name
      end
    end
  end
  table.sort(solutions)
  table.sort(projects)
  local pick = solutions[1] or projects[1]
  if not pick then
    return nil, 'no solution or project file in ' .. dir
  end
  return vim.fs.joinpath(dir, pick)
end

--- Returns the project paths of a classic .sln file, as written.
function M.parse_sln(text)
  local refs = {}
  for line in text:gmatch('[^\n]+') do
    local ref = line:match('^%s*Project%("{[^}]*}"%)%s*=%s*"[^"]*",%s*"([^"]+)"')
    if ref then refs[#refs + 1] = ref end
  end
  return refs
end

--- Returns the project paths of an XML solution file. Nested folders need
--- no special handling: every <Project Path="…"> in the file is one.
function M.parse_slnx(text)
  local refs = {}
  for ref in text:gmatch('<Project%s[^>]-Path%s*=%s*"([^"]+)"') do
    refs[#refs + 1] = ref
  end
  return refs
end

-- Strings whose presence in a project file marks it as a test project: the
-- VSTest SDK, the newer testing platform, or a test framework.
local test_markers = {
  'microsoft.net.test.sdk',
  'microsoft.testing.platform',
  '<istestproject>true',
  'include="xunit',
  'include="nunit"',
  'include="mstest',
  'include="tunit',
}

local function read_file(path)
  local fd = io.open(path, 'r')
  if not fd then return nil end
  local data = fd:read('*a')
  fd:close()
  return data
end

M.read_file = read_file

--- Reports whether the project file at path looks like a test project. It
--- reads the file only; properties inherited from Directory.Build.props are
--- not seen.
function M.is_test_project(path)
  local data = read_file(path)
  if not data then return false end
  data = data:lower()
  for _, marker in ipairs(test_markers) do
    if data:find(marker, 1, true) then return true end
  end
  return false
end

--- Returns the absolute paths of the test projects reachable from path: the
--- project itself when path is a project file, or every test project in a
--- solution. When no project in a solution looks like a test project every
--- project is returned, so listing still has something to show.
--- @return string[]|nil projects, string|nil err
function M.projects(path)
  local abs = vim.fn.fnamemodify(path, ':p'):gsub('/$', '')
  if M.is_project_file(abs) then
    if vim.uv.fs_stat(abs) == nil then
      return nil, abs .. ': no such file'
    end
    return { abs }
  end
  if not M.is_solution_file(abs) then
    return nil, path .. ': not a solution (.sln, .slnx) or project (.csproj, .fsproj, .vbproj) file'
  end
  local data = read_file(abs)
  if not data then
    return nil, abs .. ': cannot be read'
  end
  local refs = ext(abs) == '.slnx' and M.parse_slnx(data) or M.parse_sln(data)
  local dir = vim.fs.dirname(abs)
  local all, tests = {}, {}
  for _, ref in ipairs(refs) do
    local p = vim.fs.normalize(vim.fs.joinpath(dir, (ref:gsub('\\', '/'))))
    if M.is_project_file(p) then
      all[#all + 1] = p
      if M.is_test_project(p) then tests[#tests + 1] = p end
    end
  end
  if #tests == 0 then tests = all end
  table.sort(tests)
  return tests
end

return M
