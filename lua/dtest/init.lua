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

--- Ends the session: whatever is running is stopped and the results are
--- given up. Hiding is what puts the panes away for a while.
function M.close()
  require('dtest.ui').close()
end

--- Hides the panes when they are up, brings them back when they are not,
--- and starts a session when there is none. Nothing that has run is lost
--- and nothing running is stopped; a run left going behind them shows
--- them again when it finishes.
function M.toggle()
  require('dtest.ui').toggle()
end

--- Takes the panes off the screen, keeping the session.
function M.hide()
  require('dtest.ui').hide()
end

--- Puts a hidden session's panes back.
--- @param opts table|nil {focus=true} puts the cursor in them as well
function M.show(opts)
  require('dtest.ui').show(opts)
end

--- Reports whether the panes are on screen.
function M.is_open()
  return require('dtest.ui').is_open()
end

--- Reports whether there is a session at all, shown or hidden.
function M.has_session()
  return require('dtest.ui').has_session()
end

--- Runs everything, opening the panes first when they are closed. The
--- cursor stays where it is: the panes sit beside the code, so there is
--- nothing to go over to.
function M.run_all()
  local ui = require('dtest.ui')
  local session = ui.ensure_open({ focus = false })
  if not session then return end
  session:when_listed(function() ui.actions['run-all']() end)
end

--- Re-runs the tests that failed last time.
function M.run_failed()
  local ui = require('dtest.ui')
  local session = ui.ensure_open({ focus = false })
  if not session then return end
  session:when_listed(function() ui.actions['run-failed']() end)
end

-- What to open for a file: the configured target, the working directory,
-- or whatever sits above the file itself.
local function target_for(path)
  return require('dtest.dotnet.solution').find_for(path)
end

-- Runs whatever pick makes of the buffer. The buffer is read before the
-- panes open, since opening them moves the cursor to another window and
-- the file under it is no longer this one.
local function run_from_buffer(pick, opts)
  opts = opts or {}
  local ui = require('dtest.ui')
  -- Opening the panes is what moves the cursor into them; a run asked for
  -- from the code leaves it in the code, since the panes are beside it
  -- and there to be glanced at.
  local focus = opts.focus == true
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  if path == '' then
    vim.notify('dtest: this buffer has no file', vim.log.levels.WARN)
    return
  end
  path = vim.fs.normalize(path)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local row = opts.line or vim.api.nvim_win_get_cursor(0)[1]

  local session = ui.ensure_open({
    focus = false, -- moved to only once there is something to watch
    target = opts.target or target_for(path),
  })
  if not session then return end
  session:when_listed(function()
    local nodes, why = pick(session, path, lines, row)
    if not nodes or #nodes == 0 then
      ui.announce(why or ('No tests in ' .. vim.fs.basename(path)), true)
      return
    end
    -- The tree narrows to what the file holds and opens all of it, so the
    -- panes are about the file being worked on, every test of it on
    -- screen, until it is stepped back out of.
    for _, node in ipairs(nodes) do
      node:set_expanded(true)
    end
    ui.focus_on(require('dtest.tree').common_ancestor(nodes), { expand = true })
    ui.reveal(nodes[1])
    session:enqueue(nodes, { keep_open = true })
    if focus then ui.focus() end
  end)
end

--- Runs every test the current buffer's file declares.
--- @param opts table|nil {focus=, buf=, target=}; focus=true goes to the panes
function M.run_file(opts)
  run_from_buffer(function(session, path, lines)
    return session:classes_in(path, lines)
  end, opts)
end

--- Runs the test the cursor is on, or the class it is in when the cursor
--- is above the first test.
--- @param opts table|nil {focus=, buf=, line=, target=}; focus=true goes
--- to the panes
function M.run_nearest(opts)
  run_from_buffer(function(session, path, lines, row)
    local node, why = session:node_at(path, lines, row)
    return node and { node } or {}, why
  end, opts)
end

--- Runs a folder of tests: a namespace under a project, or the project
--- itself. Without a path it asks which, in Snacks' picker when that is
--- installed and in vim.ui.select otherwise.
--- @param opts table|nil {path=, focus=, target=}; focus=true goes to the
--- panes once something is running
function M.run_folder(opts)
  opts = opts or {}
  local ui = require('dtest.ui')
  local focus = opts.focus == true
  local here = vim.api.nvim_buf_get_name(0)
  local session = ui.ensure_open({
    focus = false,
    target = opts.target or (here ~= '' and target_for(vim.fs.normalize(here)) or nil),
  })
  if not session then return end
  session:when_listed(function()
    local folders = session:folders()
    if #folders == 0 then
      ui.announce('No tests to run', true)
      return
    end
    local function run(folder)
      local nodes = session:classes_under(folder)
      if #nodes == 0 then
        ui.announce('No tests in ' .. folder.path, true)
        return
      end
      -- The folder is not a node of the tree, so the view is put on the
      -- project holding it with its own classes opened and the rest left
      -- as they were.
      ui.focus_on(require('dtest.tree').common_ancestor(nodes))
      for _, node in ipairs(nodes) do
        node:set_expanded(true)
      end
      ui.reveal(nodes[1])
      session:enqueue(nodes, {
        keep_open = true,
        filter = folder.prefix and require('dtest.dotnet.filter').prefix(folder.prefix) or '',
        label = folder.path,
      })
      if focus then ui.focus() end
    end
    if opts.path then
      for _, folder in ipairs(folders) do
        if folder.path == opts.path then return run(folder) end
      end
      ui.announce('No folder of tests called ' .. opts.path, true)
      return
    end
    require('dtest.pick').folder(folders, run)
  end)
end

--- The folders a completion or a picker can offer, for the commands.
function M.folders()
  local session = require('dtest.ui').session()
  return session and session:folders() or {}
end

--- Lists the tests in the background, so that opening the panes later is
--- instant. Called for you when Neovim opens on a .NET project; calling
--- it again while one is prepared does nothing.
function M.prewarm()
  require('dtest.prewarm').start()
end

--- Rebuilds and lists the tests again.
function M.reload()
  local ui = require('dtest.ui')
  if ui.is_open() then ui.actions.reload() end
end

return M
