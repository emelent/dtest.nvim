-- The test runner: every tests/*_spec.lua returns a list of {name, fn}
-- pairs, which are run in order. Exits non-zero when one fails.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h')
vim.opt.runtimepath:prepend(root)
-- so a spec can require('tests.helper') whatever the working directory is
package.path = root .. '/?.lua;' .. package.path
vim.opt.swapfile = false

local specs = vim.fn.glob(root .. '/tests/*_spec.lua', true, true)
table.sort(specs)

local passed, failures = 0, {}
for _, path in ipairs(specs) do
  local name = vim.fn.fnamemodify(path, ':t:r')
  local suite = dofile(path)
  for _, case in ipairs(suite) do
    local ok, err = xpcall(case[2], debug.traceback)
    -- A failed case may have left the editor mid-way, so a suite gets to
    -- put things back before the next one runs.
    if suite.after_each then pcall(suite.after_each) end
    if ok then
      passed = passed + 1
    else
      failures[#failures + 1] = { name .. ' › ' .. case[1], err }
    end
  end
end

for _, failure in ipairs(failures) do
  io.stderr:write('FAIL ' .. failure[1] .. '\n' .. failure[2] .. '\n\n')
end
io.stdout:write(string.format('%d passed, %d failed\n', passed, #failures))
vim.cmd('qa' .. (#failures > 0 and '!' or '!'))
os.exit(#failures > 0 and 1 or 0)
