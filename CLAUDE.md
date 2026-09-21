# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## What this is

A Neovim plugin, in Lua, that runs the tests of a .NET solution or project
and shows them as a tree over a log, in the style of vitest. It is a port of
the `dtest` terminal app in `../dtest` (Go, bubbletea): same layout, same
keys, same colours. `README.md` documents the finished behaviour and is the
place to update when behaviour changes; `doc/dtest.txt` is the same ground
in `:help` form and drifts just as fast.

## Commands

```bash
make test                                   # the whole suite, headless
nvim --headless -u NONE -l tests/run.lua    # the same thing
make demo                                   # open the panes over ../dtest/sample
```

There is no linter in CI: `make test` on 0.10, stable and nightly is the
gate. The tests need neither the dotnet SDK nor a solution on disk.

## Architecture

The dependency direction is one way: `ui` → `session` → `tree`, `dotnet`.

- **`lua/dtest/dotnet/`** wraps the CLI. `solution.lua` finds test projects
  (.sln and .slnx), `run.lua` builds, lists and runs while streaming lines,
  `trx.lua` reads the results files, `filter.lua` builds `--filter`
  expressions and `source.lua` scans the sources for a declaration.
- **`lua/dtest/tree.lua`** is the node model: **root → project → class →
  method → case**. The root is a real node standing for the solution, so
  `node:project()` returns nil for it and callers must handle that. Status,
  counts and duration roll up from the leaves.
- **`lua/dtest/context.lua`** reads a source buffer: the classes it
  declares and which test the cursor is in. It never decides what a method
  is on its own — candidate names come from what dotnet listed — and it
  only ever looks at declarations, which is what keeps a call to another
  test from answering for it.
- **`lua/dtest/pick.lua`** asks which folder to run: Snacks' picker when
  it is installed, `vim.ui.select` when it is not. Nothing else in the
  plugin depends on a plugin, and this must not either — every call into
  Snacks is behind a `pcall`, and a picker that will not open falls back
  rather than failing.
- **`lua/dtest/prewarm.lua`** lists the tests before anyone asks, at
  `VimEnter`, and hands the session it built to `ui.open`. It is quiet
  about everything: no panes, no messages, and nothing at all when there
  is no solution to be found, since most editors are not opened on one.
- **`lua/dtest/session.lua`** is the model: the queue of runs, the batch the
  summary reports on, the raw output of each run. It knows nothing about
  windows; it calls `on_change` and the UI decides when to draw.
- **`lua/dtest/ui/`** is the panes. `render.lua` turns the session into
  lines of `{text, highlight}` segments and nothing else; `init.lua` owns
  the windows, the keymaps and the redraw.

### Hiding

The session outlives the windows. `S` holds both, but `is_open` asks only
whether the tree window is still up, while `has_session` asks whether `S`
is there at all; guards have to pick the right one. Anything that changes
what will be *drawn* (`reveal`, `focus_on`) works on a hidden session and
leaves `render` to no-op, which is what makes a run behind hidden panes
come back looking right.

`hide` empties `S.wins` **before** closing the windows, so the `WinClosed`
handler knows they are not going away under it — the same trick `close`
plays by clearing `S` first. `show` rebuilds them beside whatever is being
edited then, and clears the signatures, since new windows have nothing
drawn in them yet.

`session.on_batch_end` shows a hidden session again: tests left running
behind it are worth coming back for. `ensure_open` deliberately does not,
so a run asked for while hidden stays hidden until it is done.

### The windows

The panes are three windows beside whatever is being edited, in the tab
page `open` was called from — not a tab of their own. `is_open` asks
whether the tree window is still valid; `is_visible` also asks whether it
is on the tab being looked at, which is what decides between saying
something in the summary line and saying it out loud.

`open` builds them in one order for a reason: the log takes the new space,
the summary is split off its bottom, and only then is the tree split off,
which is what leaves the summary spanning both panes when they sit side by
side. `'equalalways'` is off while that happens, or each split would hand
every window in the tab an equal share and the space taken would grow with
every step. Sizes are measured off the window being split **before** it is
split, since by then it has already given half of itself away.

A side split takes `side_share` (a fifth) of the window it opens beside
and a split under one takes `under_share` (two thirds); `share()` floors
either at what is still readable, but only when the size was not asked for
outright. `direction_for` chooses between stacked and side by side at 2.5
columns per line (a cell is about twice as tall as it is wide). `reorient` moves
the tree with `nvim_win_set_config` when a resize changes the answer, which
is cheaper and less jarring than rebuilding the layout. Both only do
anything when the config asks for `'auto'`: the defaults pin the panes to
the right, stacked, since a sidebar that keeps its shape is worth more than
one that takes the better shape and has to be read again.

### How a run works

`Session:enqueue` turns selected nodes into requests and `pump` starts them
one at a time; everything queued since the last idle moment is one **batch**.
Running the root is special: one `dotnet test` over the solution rather than
one per project, so results come back mixed and `Tree:leaf_in` files each
under the project that listed it.

Output lines are **not** drawn as they arrive. A 100ms timer redraws while
the session is busy, so a burst of lines costs one rebuild rather than one
each; `signature()` skips the write when nothing changed, which is what
keeps the cursor and the view still.

A solution-wide run writes one .trx per project, so the trx logger is used
without `LogFileName` and every file in the results directory is read.
Naming them all the same leaves only the last project's messages.

### Folders

`Session:folders()` reads the folders out of the tree rather than off the
disk: a folder is a namespace under a project, plus the project itself.
Every namespace prefix of every class becomes an entry, so a parent folder
is offered as well as the leaf one, and its tally counts everything
beneath. The project entry has no prefix on purpose — it runs unfiltered,
so a class in some unrelated namespace still runs with it.

A folder is not a node of the tree, so `enqueue` takes `{filter, label}` to
run one expression of its own over the classes it holds.

### Running from a source buffer

`run_file` and `run_nearest` in `init.lua` read the buffer **before**
opening the panes, since opening them moves the cursor to another window.
They go through `Session:when_listed`, because the listing they need is
started by the very call that opens the panes; anything waiting is let
through when `loading` reaches zero.

Neither takes the cursor, and neither does any other command: only `open`
and `toggle` do. The panes are windows beside the code, so a run is
watched without moving into them, and `ensure_open({focus = false})` puts
the cursor back when opening them moved it. `focus = true` (the commands'
`!`) goes there once there is something to watch — after the pick, so a
buffer holding no tests never moves the cursor at all.
`session.on_batch_end` echoes the outcome when the panes are on another
tab page, where nothing can be glanced at.

They also zoom the tree, through `ui.focus_on(tree.common_ancestor(nodes),
{ expand = true })`: one class per file is the common case, so the file
becomes the tree, opened all the way down. Note the two senses of "focus"
in this code — the tab switch (`ui.focus`) and the zoom that `i` does
(`ui.focus_on`, `session.zoom`).

That unfolding would be undone seconds later by `fold_by_result`, so these
runs are enqueued with `{ keep_open = true }`, which holds the folds for
that batch only (`Session.keep_open`, cleared when the queue empties).

### Listing ahead of time

What `prewarm` prepares is a real `Session`, not a cache, so `ui.open`
takes it over rather than copying out of it — a listing still going when
the panes open is shown filling in. `take` is the only way to get it, and
it refuses what no longer fits: another target, or options changed since,
which happens because a lazily loaded plugin runs `setup()` after
`plugin/dtest.lua` is sourced. A `BufWritePost` on a source or project
file only marks the listing **stale**; it is not redone until the panes
open, and then over the tree already there, which stays readable
meanwhile.

`plugin/dtest.lua` starts it at `VimEnter`, or right away when the file is
sourced later than that, as it is when lazily loaded.

### Which failure `o` opens

A group's log is several tests' failures, and then its skips, one after
another, so the tree's selected node cannot say which one is being read.
`render.node_log` tags every line of a test's block with the leaf it came
from (`line.node`, a named field, which `M.text` steps over since it
iterates with `ipairs`), `draw_log` keeps the rendered lines in
`S.log_lines`, and `open-in-editor` reads the tag under the cursor. A location parsed from the line itself
still wins, being the more specific answer.

### Keys go through actions

`config.keys` maps an action name to keys; `ui.actions` holds one function
per action. Adding a binding means adding a function to `ui.actions`, a
default to `config.defaults.keys`, and a row to `help_rows` in `render.lua`.
The help screen looks bindings up when it draws, so never hardcode a key in
user-facing text — use `config.key_for()`.

`tree_only` in `ui/init.lua` lists the actions bound in the tree pane alone,
because the log wants those keys for Neovim's own: `n`, `N`, `/`.

The filter prompt (`ui/prompt.lua`) is deliberately outside the keymap:
while it is open almost every key is literal text.

### Visual conventions

Worth preserving when touching the drawing code, because they were asked
for specifically:

- The three outcome colours are washed shades, not the terminal's red,
  green and yellow. The tree draws every colour a shade back
  (`DtestTree*`), so the summary is the line that carries.
- Durations follow vitest: green under 300ms, yellow over, with the unit a
  faded shade of the number's colour.
- The tree root shows only what the solution holds; results and times
  belong to the rows below it. A group's log shows its failures and then
  what it skipped, not its tally, which the row it was selected from
  already carries. The tree counts outcomes in glyphs (`×1`, `⊘1`); the
  words are the footer's, which is the line meant to be read at a glance.
  A failed or skipped test wears its outcome's faded colour in the tree,
  name and all.
- A failure wears a red ` FAIL ` badge in the log and a skip an amber
  ` SKIP ` one (`DtestBadgeFail`, `DtestBadgeSkip`): the same shape, so
  both read at a glance without being mistaken for each other.
- Exactly one spinner, on the running project. The log never animates.

## Testing

`tests/helper.lua` stands in for the dotnet CLI by replacing
`dtest.dotnet.run.system`: a stub is handed the command line and plays back
lines, an exit code and a .trx written into the run's results directory.
`tests/ui_spec.lua` drives the real session and the real windows through
`ui.actions`, so a test that passes is the plugin working, not a mock of it.

Restore what you replace: `t.restore_dotnet()` and `config.setup({})` at the
end of a test that changed either.

## Writing code here

Comments explain **why**, not what, and carry the reasoning behind a choice
that looks arbitrary (why a project is never auto-folded, why the timer is
wall-clock, why the trx logger is left unnamed). Doc comments on every
module-level function.

Update `README.md` and `doc/dtest.txt` alongside behaviour changes.
