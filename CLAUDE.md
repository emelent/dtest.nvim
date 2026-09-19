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
- **`lua/dtest/session.lua`** is the model: the queue of runs, the batch the
  summary reports on, the raw output of each run. It knows nothing about
  windows; it calls `on_change` and the UI decides when to draw.
- **`lua/dtest/ui/`** is the panes. `render.lua` turns the session into
  lines of `{text, highlight}` segments and nothing else; `init.lua` owns
  the windows, the keymaps and the redraw.

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

### Running from a source buffer

`run_file` and `run_nearest` in `init.lua` read the buffer **before**
opening the panes, since opening them moves the cursor to another window.
They go through `Session:when_listed`, because the listing they need is
started by the very call that opens the panes; anything waiting is let
through when `loading` reaches zero.

Both end up in the panes, but *when* they switch differs on purpose: panes
that have to be opened are switched to at once, since opening moves there
anyway, while panes already open are joined only once the pick has found
something — so a buffer holding no tests never yanks the cursor out of it.
`session.on_batch_end` echoes the outcome when the dtest tab is not the one
being looked at, which is what makes `focus = false` usable.

They also zoom the tree, through `ui.focus_on(tree.common_ancestor(nodes))`:
one class per file is the common case, so the file becomes the tree. Note
the two senses of "focus" in this code — the tab switch (`ui.focus`) and the
zoom that `i` does (`ui.focus_on`, `session.zoom`).

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
  belong to the rows below it. A group's log shows its failures, not its
  tally, which the row it was selected from already carries.
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
