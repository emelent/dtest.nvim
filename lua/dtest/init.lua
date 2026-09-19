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

--- Rebuilds and lists the tests again.
function M.reload()
  local ui = require('dtest.ui')
  if ui.is_open() then ui.actions.reload() end
end

return M
