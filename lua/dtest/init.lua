-- dtest.nvim: run the tests of a .NET solution or project from Neovim,
-- with a UI in the spirit of vitest.
local config = require('dtest.config')

local M = {}

--- Merges opts over the defaults and defines the highlight groups. Calling
--- it is optional: the defaults stand until it is.
function M.setup(opts)
  config.setup(opts)
  require('dtest.ui.hl').setup()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('dtest.colors', { clear = true }),
    callback = function() require('dtest.ui.hl').setup() end,
  })
end

--- Opens the panes for target, or for whatever the working directory holds.
function M.open(target)
  require('dtest.ui').open(target)
end

function M.close()
  require('dtest.ui').close()
end

function M.toggle()
  require('dtest.ui').toggle()
end

function M.is_open()
  return require('dtest.ui').is_open()
end

--- Runs everything, opening the panes first when they are closed.
function M.run_all()
  local ui = require('dtest.ui')
  if not ui.is_open() then ui.open() end
  ui.actions['run-all']()
end

--- Re-runs the tests that failed last time.
function M.run_failed()
  local ui = require('dtest.ui')
  if not ui.is_open() then ui.open() end
  ui.actions['run-failed']()
end

-- What to open for a file when nothing is configured: the working
-- directory first, so :Dtest and these agree, and failing that whatever
-- sits above the file itself.
local function target_for(path)
  local solution = require('dtest.dotnet.solution')
  if config.options.target then return config.options.target end
  if solution.find_target(vim.uv.cwd()) then return nil end -- open() finds it
  return solution.find_upward(vim.fs.dirname(path))
end

-- Runs whatever pick makes of the buffer. The buffer is read before the
-- panes open, since opening them moves the cursor to another window and
-- the file under it is no longer this one.
local function run_from_buffer(pick, opts)
  opts = opts or {}
  local ui = require('dtest.ui')
  -- The panes are where the results are, so that is where this ends up,
  -- unless it is asked to run in the background.
  local focus = opts.focus ~= false
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  if path == '' then
    vim.notify('dtest: this buffer has no file', vim.log.levels.WARN)
    return
  end
  path = vim.fs.normalize(path)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local row = opts.line or vim.api.nvim_win_get_cursor(0)[1]

  -- Opening the panes moves there anyway, so it happens at once; panes
  -- that are already open are joined only once there is something to
  -- watch, so a buffer holding no tests never pulls the cursor out of it.
  local was_open = ui.is_open()
  local session = ui.ensure_open({
    focus = focus and not was_open,
    target = opts.target or target_for(path),
  })
  if not session then return end
  session:when_listed(function()
    local nodes, why = pick(session, path, lines, row)
    if not nodes or #nodes == 0 then
      ui.announce(why or ('No tests in ' .. vim.fs.basename(path)), true)
      return
    end
    ui.reveal(nodes[1])
    session:enqueue(nodes)
    if focus then ui.focus() end
  end)
end

--- Runs every test the current buffer's file declares, and shows them.
--- @param opts table|nil {focus=, buf=, target=}; focus=false stays put
function M.run_file(opts)
  run_from_buffer(function(session, path, lines)
    return session:classes_in(path, lines)
  end, opts)
end

--- Runs the test the cursor is on, or the class it is in when the cursor
--- is above the first test, and shows it.
--- @param opts table|nil {focus=, buf=, line=, target=}; focus=false stays put
function M.run_nearest(opts)
  run_from_buffer(function(session, path, lines, row)
    local node, why = session:node_at(path, lines, row)
    return node and { node } or {}, why
  end, opts)
end

--- Rebuilds and lists the tests again.
function M.reload()
  local ui = require('dtest.ui')
  if ui.is_open() then ui.actions.reload() end
end

return M
