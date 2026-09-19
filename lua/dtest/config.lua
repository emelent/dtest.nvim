-- Defaults and whatever setup() was given. Keys are bound to actions
-- rather than handled directly, so rebinding one never disturbs another:
-- an action's list replaces its default outright, and an empty list unbinds
-- it.
local M = {}

M.defaults = {
  -- The solution or project to test. nil means: look for one in the
  -- working directory when the plugin opens.
  target = nil,
  configuration = nil, -- build configuration passed to dotnet (-c)
  no_build = false,    -- never build; list and run against existing binaries
  build_on_open = true,

  layout = {
    log_ratio = 0.65, -- the share of the height the log pane takes
    footer = true,    -- the two summary lines along the bottom
  },

  icons = {
    passed = '✓',
    failed = '×',
    skipped = '↓',
    none = '·',
    queued = '⧗', -- an hourglass: scheduled in a run that has not started
    arrow = '❯',  -- marks a source location line in the log
    open = '▾',   -- an expanded project, class or theory
    closed = '▸', -- a collapsed one
    rule = '⎯',
    spinner = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' },
  },

  -- Either a highlight-group table ({ fg = '#d78787', bold = true }) or the
  -- name of a group to link to. The three outcome colours are washed
  -- shades rather than the terminal's own red, green and yellow, which are
  -- meant to shout and would, on a screen that is mostly results.
  colors = {
    passed = { fg = '#87af87', ctermfg = 108 },
    failed = { fg = '#af5f5f', ctermfg = 131 },
    skipped = { fg = '#af875f', ctermfg = 137 },
    running = { fg = '#5fafaf', ctermfg = 6 },
    dim = { fg = '#6c6c6c', ctermfg = 8 },
    badge = { fg = '#ffffff', ctermfg = 15 },
  },

  keys = {
    -- Motions inside a pane are Neovim's own; these are the actions on top.
    ['switch-pane'] = { '<C-j>', '<C-k>', '<Tab>', '<S-Tab>' },
    ['expand'] = { 'l', '<Right>' },
    ['collapse'] = { 'h', '<Left>' },
    ['expand-all'] = { 'L' },
    ['collapse-all'] = { 'H' },
    ['toggle-fold'] = { '<Space>' },
    ['focus'] = { 'i' },
    ['unfocus'] = { 'I' },
    ['run'] = { '<CR>', 'r' },
    ['run-all'] = { 'A' },
    ['run-failed'] = { 'F' },
    ['only-failed'] = { 'f' },
    ['only-skipped'] = { 's' },
    ['show-all'] = { 'a' },
    ['clear'] = { '<Esc>' },
    ['cancel'] = { 'x' },
    ['next-failure'] = { 'n' },
    ['previous-failure'] = { 'N' },
    ['open-in-editor'] = { 'o' },
    ['filter'] = { 't', '/' },
    ['toggle-output'] = { 'v' },
    ['reload'] = { '<C-r>' },
    ['help'] = { '?' },
    ['quit'] = { 'q' },
  },
}

M.options = vim.deepcopy(M.defaults)

--- Merges user options over the defaults. A key's list replaces the
--- default outright, which deep-merging a list would not do.
function M.setup(opts)
  opts = opts or {}
  local merged = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts)
  for action, keys in pairs(opts.keys or {}) do
    merged.keys[action] = keys
  end
  M.options = merged
  return merged
end

--- The first key bound to an action, for the help screen, or a dash when
--- it has been unbound.
function M.key_for(action)
  local keys = M.options.keys[action]
  if keys == nil then return '–' end
  if type(keys) == 'string' then return keys end
  return keys[1] or '–'
end

--- Every key bound to each action, "j / k".
function M.keys_for(...)
  local out = {}
  for _, action in ipairs({ ... }) do
    out[#out + 1] = M.key_for(action)
  end
  return table.concat(out, ' / ')
end

--- The keys bound to an action, always as a list.
function M.bindings(action)
  local keys = M.options.keys[action]
  if keys == nil then return {} end
  if type(keys) == 'string' then return { keys } end
  return keys
end

return M
