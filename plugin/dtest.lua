-- The user commands. Everything else loads on demand.
if vim.g.loaded_dtest then
  return
end
vim.g.loaded_dtest = true

local function complete(arg)
  return vim.fn.getcompletion(arg, 'file')
end

vim.api.nvim_create_user_command('Dtest', function(cmd)
  require('dtest').open(cmd.args ~= '' and cmd.args or nil)
end, { nargs = '?', complete = complete, desc = 'Open dtest for a solution or project' })

vim.api.nvim_create_user_command('DtestToggle', function()
  require('dtest').toggle()
end, { desc = 'Open or close dtest' })

vim.api.nvim_create_user_command('DtestClose', function()
  require('dtest').close()
end, { desc = 'Close dtest' })

vim.api.nvim_create_user_command('DtestRun', function()
  require('dtest').run_all()
end, { desc = 'Run every test' })

vim.api.nvim_create_user_command('DtestRunFailed', function()
  require('dtest').run_failed()
end, { desc = 'Re-run the tests that failed last time' })

vim.api.nvim_create_user_command('DtestFile', function(cmd)
  require('dtest').run_file({ focus = cmd.bang })
end, { bang = true, desc = "Run the tests in this buffer's file (! goes to the panes)" })

vim.api.nvim_create_user_command('DtestNearest', function(cmd)
  require('dtest').run_nearest({ focus = cmd.bang })
end, { bang = true, desc = 'Run the test the cursor is on (! goes to the panes)' })

vim.api.nvim_create_user_command('DtestFolder', function(cmd)
  require('dtest').run_folder({ path = cmd.args ~= '' and cmd.args or nil, focus = cmd.bang })
end, {
  bang = true,
  nargs = '?',
  complete = function(arg)
    local paths = {}
    for _, folder in ipairs(require('dtest').folders()) do
      if folder.path:find(arg, 1, true) == 1 then paths[#paths + 1] = folder.path end
    end
    return paths
  end,
  desc = 'Run a folder of tests, choosing which (! goes to the panes)',
})

vim.api.nvim_create_user_command('DtestReload', function()
  require('dtest').reload()
end, { desc = 'Rebuild and list the tests again' })
