-- The palette. Every group is defined from the six colours in the config,
-- so repainting one repaints everything derived from it. The tree wears a
-- faded shade of each colour, so the tree stays the quiet half of the
-- screen and the footer's colours, which are the ones meant to be read at
-- a glance, carry.
local config = require('dtest.config')

local M = {}

M.ns = vim.api.nvim_create_namespace('dtest')

-- Multiplies a #rrggbb string towards black; nil for anything else, so a
-- link or a group without a gui colour simply keeps what it has.
local function fade(hex, factor)
  if type(hex) ~= 'string' then return nil end
  local n = tonumber(hex:match('^#(%x%x%x%x%x%x)$') or '', 16)
  if not n then return nil end
  local r = math.floor(math.floor(n / 65536) % 256 * factor)
  local g = math.floor(math.floor(n / 256) % 256 * factor)
  local b = math.floor(n % 256 * factor)
  return string.format('#%02x%02x%02x', r, g, b)
end

-- A colour from the config as a highlight definition. A string names a
-- group to link to; a table is used as it stands.
local function spec(value)
  if type(value) == 'string' then return { link = value } end
  return vim.deepcopy(value or {})
end

local function faded(value, factor)
  local s = spec(value)
  if s.link then return s end
  s.fg = fade(s.fg, factor) or s.fg
  return s
end

local function with(value, extra)
  return vim.tbl_extend('force', spec(value), extra)
end

-- Blends two 24-bit colours; used for the cursor line of the pane that
-- does not have focus, which stays visible but stops competing with the
-- one that does.
local function blend(a, b, amount)
  if type(a) ~= 'number' or type(b) ~= 'number' then return nil end
  local function mix(shift)
    local x = math.floor(a / shift) % 256
    local y = math.floor(b / shift) % 256
    return math.floor(x * amount + y * (1 - amount))
  end
  return string.format('#%02x%02x%02x', mix(65536), mix(256), mix(1))
end

-- The cursor line of the unfocused pane: halfway from the focused one back
-- to the background, or the colourscheme's own CursorLine when either
-- colour is unknown.
local function cursor_line_nc()
  local cursor = vim.api.nvim_get_hl(0, { name = 'CursorLine', link = false })
  local normal = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
  local bg = blend(cursor.bg, normal.bg, 0.5)
  if not bg then return { link = 'CursorLine' } end
  return { bg = bg, ctermbg = cursor.ctermbg }
end

--- (Re)defines every highlight group from the configured colours. Groups
--- are defined with default = true, so a colourscheme or a user :highlight
--- keeps the last word.
function M.setup()
  local c = config.options.colors
  local groups = {
    DtestPassed = spec(c.passed),
    DtestFailed = spec(c.failed),
    DtestSkipped = spec(c.skipped),
    DtestRunning = spec(c.running),
    DtestQueued = spec(c.dim),
    DtestDim = spec(c.dim),
    DtestRule = faded(c.dim, 0.7),
    DtestBold = { bold = true },
    DtestKey = with(c.running, { bold = true }),
    DtestCommand = spec(c.running),
    DtestError = spec(c.failed),
    DtestExpected = spec(c.passed),
    DtestActual = spec(c.failed),
    DtestLocation = spec(c.running),
    DtestElapsed = faded(c.running, 0.8),

    -- Durations, vitest's way: green while quick, yellow once slow, the
    -- unit a faded shade of the number's own colour so the number reads
    -- first.
    DtestQuick = spec(c.passed),
    DtestSlow = spec(c.skipped),
    DtestQuickUnit = faded(c.passed, 0.7),
    DtestSlowUnit = faded(c.skipped, 0.7),

    -- The tree's shade-back variants.
    DtestTreePassed = faded(c.passed, 0.78),
    DtestTreeFailed = faded(c.failed, 0.78),
    DtestTreeSkipped = faded(c.skipped, 0.78),
    DtestTreeRunning = faded(c.running, 0.78),
    DtestTreeQuick = faded(c.passed, 0.78),
    DtestTreeSlow = faded(c.skipped, 0.78),
    DtestTreeQuickUnit = faded(c.passed, 0.55),
    DtestTreeSlowUnit = faded(c.skipped, 0.55),

    DtestCursorLine = { link = 'CursorLine' },
    DtestCursorLineNC = cursor_line_nc(),

    DtestBadgeFail = { fg = spec(c.badge).fg, bg = spec(c.failed).fg,
      ctermfg = spec(c.badge).ctermfg, ctermbg = spec(c.failed).ctermfg, bold = true },
    DtestBadgeInfo = { fg = '#000000', bg = spec(c.running).fg,
      ctermfg = 0, ctermbg = spec(c.running).ctermfg, bold = true },
  }
  for name, def in pairs(groups) do
    def.default = true
    vim.api.nvim_set_hl(0, name, def)
  end
end

return M
