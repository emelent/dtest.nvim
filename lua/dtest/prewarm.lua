-- Listing the tests before anyone asks for them. Neovim opening on a .NET
-- project is as good a moment as any to build once and run
-- `dotnet test --list-tests`, so that opening the panes is instant rather
-- than a wait; the session it prepares is the very one they then use.
local config = require('dtest.config')
local session_mod = require('dtest.session')
local solution = require('dtest.dotnet.solution')

local M = {}

-- The session listing in the background, if any, and whether anything has
-- been saved since it did.
local prepared = nil

-- Files whose saving makes a listing out of date.
local watched = { '*.cs', '*.fs', '*.vb', '*.csproj', '*.fsproj', '*.vbproj', '*.sln', '*.slnx' }

--- Forgets what was prepared, stopping it if it is still going.
function M.discard()
  if not prepared then return end
  prepared.session:shutdown()
  pcall(vim.api.nvim_del_augroup_by_name, 'dtest.prewarm')
  prepared = nil
end

--- Reports whether a listing is prepared or under way.
function M.pending()
  return prepared ~= nil
end

--- The session being prepared, for asking how far along it is.
function M.session()
  return prepared and prepared.session or nil
end

--- Starts listing the tests of whatever this Neovim is sitting in. It is
--- quiet about everything: no panes, no messages, and nothing at all when
--- there is no solution to be found, since most editors are not opened on
--- one.
function M.start()
  if prepared or not config.options.prewarm then return end
  if require('dtest.ui').has_session() then return end
  local here = vim.api.nvim_buf_get_name(0)
  local target = solution.find_for(here ~= '' and vim.fs.normalize(here) or nil)
  if not target or vim.uv.fs_stat(target) == nil then return end

  local session = session_mod.new(target, {
    configuration = config.options.configuration,
    no_build = config.options.no_build,
  })
  prepared = { session = session, stale = false }
  local group = vim.api.nvim_create_augroup('dtest.prewarm', { clear = true })
  -- A file saved after the listing may have added or renamed a test, so
  -- what was prepared is worth listing again when it is taken up.
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    pattern = watched,
    callback = function()
      if prepared then prepared.stale = true end
    end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = M.discard })
  session:start()
end

-- Whether what was prepared is still what is being asked for. A lazily
-- loaded plugin runs `setup()` after this file is sourced, so the options
-- the listing was made under are not always the ones in force when the
-- panes open.
local function still_good(session, target)
  if target and session.target ~= target then return false end
  local opts = config.options
  if not opts.prewarm then return false end
  return session.opts.configuration == opts.configuration
    and session.opts.no_build == opts.no_build
end

--- Hands the prepared session over, and says whether anything has been
--- saved since it listed. A session prepared for another solution, or
--- under options since changed, is dropped rather than handed over.
--- @return table|nil session, boolean stale
function M.take(target)
  if not prepared then return nil, false end
  local session, stale = prepared.session, prepared.stale
  if not still_good(session, target) then
    M.discard()
    return nil, false
  end
  prepared = nil
  pcall(vim.api.nvim_del_augroup_by_name, 'dtest.prewarm')
  return session, stale
end

return M
