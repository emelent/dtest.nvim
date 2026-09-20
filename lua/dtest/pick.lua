-- Choosing something to run. Snacks' picker when it is installed, since
-- that is what a fuzzy list looks like here, and vim.ui.select otherwise,
-- which is whatever the editor has been told to use for a choice.
local util = require('dtest.util')

local M = {}

-- How the two halves of a row are laid out: the path, then how many tests
-- are under it, far enough over to line up.
local function columns(items)
  local widest = 0
  for _, item in ipairs(items) do
    widest = math.max(widest, vim.fn.strdisplaywidth(item.path))
  end
  return math.min(widest, 60)
end

--- Snacks' picker, or nil when it is not there to be had.
local function snacks_picker()
  local ok, snacks = pcall(require, 'snacks')
  if not ok or type(snacks) ~= 'table' then return nil end
  local picker = rawget(snacks, 'picker') or snacks.picker
  if type(picker) ~= 'table' or type(picker.pick) ~= 'function' then return nil end
  return picker
end

--- Asks which of items to run and hands the answer to on_choose. Nothing
--- is called when the choice is abandoned.
--- @param items table[] {path=, count=, …}
function M.folder(items, on_choose)
  local width = columns(items)
  local function tally(item)
    return util.plural(item.count, 'test')
  end

  local picker = snacks_picker()
  if picker then
    local rows = {}
    for i, item in ipairs(items) do
      -- text is what the fuzzy matcher reads; the rest rides along.
      rows[i] = { text = item.path, idx = i, folder = item }
    end
    local ok = pcall(picker.pick, {
      source = 'dtest_folders',
      title = 'dtest folders',
      items = rows,
      -- A folder is not a file, so there is nothing to preview; the list
      -- on its own is the shape a choice wants. Both are overridable
      -- under Snacks' sources.dtest_folders.
      preview = false,
      layout = { preset = 'select' },
      format = function(row)
        return {
          { row.folder.path, 'DtestBold' },
          { string.rep(' ', math.max(1, width + 2 - vim.fn.strdisplaywidth(row.folder.path))) },
          { tally(row.folder), 'DtestDim' },
        }
      end,
      actions = {
        confirm = function(self, row)
          self:close()
          if row then
            vim.schedule(function() on_choose(row.folder) end)
          end
        end,
      },
    })
    if ok then return end
    -- A picker that would not open is no reason to be unable to choose.
  end

  vim.ui.select(items, {
    prompt = 'Run the tests in',
    kind = 'dtest_folders',
    format_item = function(item)
      return string.format('%-' .. width .. 's  %s', item.path, tally(item))
    end,
  }, function(choice)
    if choice then on_choose(choice) end
  end)
end

return M
