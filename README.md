# dtest.nvim

Run the tests of a .NET solution or project from Neovim, with a UI in the
spirit of vitest. It is a Lua port of [dtest](../dtest), the terminal app:
the same two panes, the same tree, the same colours and the same keys, but
inside the editor, so opening the source of a failing test is a keystroke
rather than a hand-off.

It drives the `dotnet` CLI: builds once, lists every test, and runs
whatever the tree selects while the screen updates live.

```
⎯⎯ Log  Shop.Api.Tests › Middleware.RateLimitMiddlewareTests › OverLimit_Returns429 ⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯
  × Shop.Api.Tests › Middleware.RateLimitMiddlewareTests › OverLimit_Returns429

   FAIL  Shop.Api.Tests › Middleware.RateLimitMiddlewareTests › OverLimit_Returns429 0.001s
Assert.Equal() Failure: Values differ
Expected: 429
Actual:   428
 ❯ tests/Shop.Api.Tests/Middleware/RateLimitMiddlewareTests.cs:12

  Stack trace
   at Shop.Api.Tests.Middleware.RateLimitMiddlewareTests.OverLimit_Returns429() in …:line 12

⎯⎯ Tests ⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯
  ▾ Shop (2 projects | 49 tests)
  ├─ ▾ Shop.Api.Tests (16 tests | 2 failed | 1 skipped) 0.82s
  │  ├─ ▾ Controllers.OrdersControllerTests (3 tests | 1 failed) 0.005s
  │  │  ├─ × Get_Paginates 0.000s
  │  │  ├─ ✓ Post_CreatesOrder 0.000s
  │  │  └─ ✓ Post_EmptyBody_Returns400 0.003s
  │  ├─ ▸ Controllers.ProductsControllerTests (4 tests) 0.004s
  │  ├─ ▸ Integration.CheckoutFlowTests (2 tests | 1 skipped) 0.804s
  │  └─ ▾ Middleware.RateLimitMiddlewareTests (2 tests | 1 failed) 0.003s
  │     ├─ × OverLimit_Returns429 0.001s
  │     └─ ✓ UnderLimit_Passes 0.002s
  └─ ▸ Shop.Core.Tests (33 tests | 2 failed | 1 skipped) 1.2s

 Ran 49 tests in 2.1s at 23:37:56
 4 failed | 43 passed | 2 skipped
```

## Layout

`:Dtest` opens beside the window you are in, so the code stays on screen.
Which way round the panes go follows the shape of the space they are
given, and is re-checked when the terminal is resized:

```
wide space                          tall space
┌──────────┬───────────────┐        ┌───────────────────────┐
│ Tests    │ Log           │        │ Log             70%   │
│ 30%      │ 70%           │        ├───────────────────────┤
├──────────┴───────────────┤        │ Tests           30%   │
│ Ran 8 tests · 1 failed   │        ├───────────────────────┤
└──────────────────────────┘        │ Ran 8 tests · 1 failed│
                                    └───────────────────────┘
```

A terminal cell is about twice as tall as it is wide, so "wide" means
comfortably past square: once the space is at least 2.5 columns per line,
the tree takes the left 30% and the log the right 70%; otherwise the log
takes the top 70% and the tree the bottom 30%. The summary spans both
either way. `layout.direction` pins one of them if you would rather not
have it decided for you.

The panes themselves are carved out of the window `:Dtest` was called
from: beside it when that window is wide, under it when it is not. Beside
it they take a fifth of it, the way a sidebar does, and under it two
thirds, there being no code alongside to crowd; either way never so little
that they cannot be read. `layout.position` and `layout.size` say
otherwise — `size = 0.35` for a wider column, say. `<C-j>` / `<C-k>` or `<Tab>` move between the two panes; `q`
closes them and puts you back where you started.

- **Log** (the larger pane, 70%) shows the results of whatever the tree
  selects. For a test: its verdict, message (expected values green,
  actual values red), failing location, stack trace and captured output.
  For the solution, a project, a class or a theory: every failure beneath
  it, without the tally, which the tree row it was selected from already
  carries. Build errors show first. It is an ordinary buffer, so `j`/`k`,
  `gg`/`G`, `/` and `n` work as they always do, and `V` then `y` yanks
  lines out of a stack trace into your own register. `v` swaps in the raw
  `dotnet` output of the selected project, coloured by kind.
- **Tests** (the other 30%) is the tree of projects, classes, methods and
  theory rows under a root that stands for the solution itself, drawn with branch
  lines (`├─`, `└─`, `│`) so the nesting reads at a glance, with
  vitest-style counts and durations on every group. The root's own row just
  says what the solution holds, `2 projects | 49 tests`; selecting it shows
  the whole solution at once and running it runs `dotnet test` over the
  solution in one go. Projects start collapsed, so a fresh tree is a list
  of them. After a run, passing classes fold to one line and failing ones
  open, and a project is only ever opened by that, never folded shut under
  you.
- **Summary** (two lines along the bottom, spanning both panes) says what
  the batch was, `Ran 49 tests
  in 2.1s at 23:37:56`, and under it how it went, `4 failed | 43 passed |
  2 skipped`. It counts results in live and keeps that one shape from the
  first to the last, so the lines settle rather than changing form when the
  batch ends, and an outcome still at zero is greyed rather than missing.
  What dtest is doing, and anything it has to say, takes the first of those
  lines while there is something to say, leaving the outcomes on the one
  below.

Moving the cursor in the tree is what changes the log: there is no separate
selection to keep track of.

## Features

- Run the selected root, project, class, method or test; `A` and running
  the root both run the whole solution in one `dotnet test`, `F` re-runs
  only what failed; anything smaller is one `dotnet test` per project, and
  runs queue up
- Live status while tests run: the summary counts results in as they land,
  the project row spins and everything running beneath it turns cyan, tests
  waiting in a queued run are greyed out behind an hourglass, ⧗; ✓ × ↓
  arrive as each result comes in; projects, classes and theories carry a
  fold arrow (▾ / ▸) in the colour of their status, with counts and
  durations rolled up
- `o` opens the source in the window you came from: the stack frame under
  the log cursor, else a failed test's failing line, else the declaration
- Filter the tree by test or project name as you type, or narrow it to the
  failed (`f`) or skipped (`s`) tests
- `i` focuses the view on the selected project or class: it becomes the
  root of the tree, drawn flush, and from then on the plugin behaves as
  though its tests were the only ones, down to what `A` runs and where `n`
  looks for the next failure. `I` steps back out one level.

## Requirements

- Neovim 0.10 or newer (0.11 is what it is developed against)
- The `dotnet` SDK on your `PATH`, with test projects using the VSTest
  runner (`Microsoft.NET.Test.Sdk` with xUnit, NUnit or MSTest)

No other plugins, and nothing to compile. [Snacks](https://github.com/folke/snacks.nvim)
is used for the `:DtestFolder` list when it happens to be installed;
without it the choice goes through `vim.ui.select`.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'emelent/nvim-dtest',
  -- Every command, or the ones left out will not exist until one of these
  -- has loaded the plugin.
  cmd = {
    'Dtest', 'DtestToggle', 'DtestClose',
    'DtestRun', 'DtestRunFailed', 'DtestReload',
    'DtestFile', 'DtestNearest', 'DtestFolder',
  },
  keys = {
    { '<leader>tt', function() require('dtest').run_nearest() end, desc = 'Run the test at the cursor' },
    { '<leader>tf', function() require('dtest').run_file() end, desc = 'Run the tests in this file' },
  },
  opts = {},
}
```

Leaving `cmd` out altogether loads it at startup, which costs nothing much:
`plugin/dtest.lua` registers the commands and requires nothing else until
one of them is run.

With [packer](https://github.com/wbthomason/packer.nvim):

```lua
use { 'dtest-nvim', config = function() require('dtest').setup({}) end }
```

Or clone it into a `pack` directory and call `require('dtest').setup({})`
from your config. `setup()` is optional: without it the defaults stand and
the commands still work.

## Usage

| Command | What it does |
| --- | --- |
| `:Dtest [target]` | Open the panes for a solution or project file, for a directory, or for whatever the working directory holds |
| `:DtestToggle` | Show the panes, or hide them when they are up, keeping the session |
| `:DtestClose` | End the session: stop whatever dotnet is doing and give up the results |
| `:DtestRun` | Open if needed, then run every test |
| `:DtestRunFailed` | Re-run the tests that failed last time |
| `:DtestFile[!]` | Run the tests in the file you are editing (`!` goes to the panes) |
| `:DtestNearest[!]` | Run the test the cursor is on (`!` goes to the panes) |
| `:DtestFolder[!] [path]` | Run a folder of tests, choosing which from a fuzzy list (`!` goes to the panes) |
| `:DtestReload` | Rebuild and list the tests again |

The same from Lua: `require('dtest').open(target)`, `.toggle()`,
`.hide()`, `.show(opts)`, `.close()`, `.run_all()`, `.run_failed()`,
`.run_file(opts)`, `.run_nearest(opts)`, `.run_folder(opts)`, `.reload()`,
`.is_open()`, `.has_session()`.

### Hiding, and coming back

Hiding is not closing. `:DtestToggle` (and `q` in the panes) takes the
windows off the screen and leaves everything else standing: the tree, the
results, the logs, and any `dotnet test` still going. Toggling again puts
them back, beside whatever you are editing then rather than where they
were before.

So a slow suite can be started, put away, and worked over the top of — and
when the last test of the run lands, **the panes show themselves again**
with the results, without taking the cursor. A run asked for while they
are hidden stays hidden until it is done, which is the point of putting
them away.

`:DtestClose` is the one that ends a session: it stops whatever dotnet is
doing and gives up the results.

**Only `:Dtest` and `:DtestToggle` take the cursor.** Every other command
opens the panes if they are closed and then leaves you where you were —
they sit beside the code to be glanced at, not moved into. Pass `!` (or
`{ focus = true }`) to the run commands to be taken there anyway.

### A folder of tests

`:DtestFolder` asks which folder to run and runs it:

```
╭──────────────────────── dtest folders ─────────────────────────╮
│ valid                                                     1/9 │
│────────────────────────────────────────────────────────────────│
│ Shop.Core.Tests/Orders/Validation  9 tests                     │
╰────────────────────────────────────────────────────────────────╯
```

The list is built from the tree, so every entry is a folder that really
holds tests, with everything under it counted — picking `Orders` runs
`Orders/Validation` too. A project is a folder like any other and runs
unfiltered; a namespace runs as one `FullyQualifiedName~Ns.` filter rather
than one expression per class. The tree is focused on what ran, its
classes opened, while your cursor stays where it was.

Folders are namespaces, which .NET lays out as directories by convention.
A `path` argument skips the prompt — `:DtestFolder Shop.Core.Tests/Pricing`
— and completes on the folders the open session knows.

The list is shown in [Snacks](https://github.com/folke/snacks.nvim)'
picker when that is installed, under the source name `dtest_folders`, so
`Snacks.picker.config.sources.dtest_folders` can change its layout or keys.
Without Snacks it goes through `vim.ui.select`, which is whatever your
editor already uses for a choice.

### From the file you are editing

`:DtestFile` and `:DtestNearest` work from a source buffer rather than from
the tree, so a test can be run without leaving the line being written.

- **`:DtestFile`** runs every test class the buffer declares.
- **`:DtestNearest`** runs the test the cursor is in: the nearest
  declaration at or above it, counting an attribute line as part of the
  test under it, so `[Fact]` and `[Theory]` do the expected thing. Above
  the first test of a class — in the usings, or on the class itself — the
  class is what runs. A theory runs all of its rows, since a single row
  cannot be addressed by name.

Neither takes the cursor: the panes open beside the buffer if they were
closed, and you carry on typing while the tree fills in. What the tree
shows is **focused on what the file holds** — the class it declares
becomes the root of the tree, drawn flush, exactly as `i` would, and every
test under it is unfolded, theory rows and all. From then on `A` runs that
class and `n` looks for failures inside it; `I` steps back out a level at a
time. The tree stays open through that run rather than folding its passing
groups away at the end, since opening it was the point; the next run
started from the panes reads as a report again. A file declaring several classes focuses the project they
share. A buffer holding nothing dtest knows about is the exception: there
is nothing to watch, so it says so and leaves you where you are.

```lua
vim.keymap.set('n', '<leader>tt', function() require('dtest').run_nearest() end)
vim.keymap.set('n', '<leader>tf', function() require('dtest').run_file() end)
vim.keymap.set('n', '<leader>ta', require('dtest').run_all)
```

Add a `!` (or pass `{ focus = true }`) to be taken to the panes when the
run starts.

When the panes are on a tab you are not looking at, how the run went is
echoed when it finishes instead:

```
dtest: Shop — 1 failed | 7 passed | 0 skipped
```

Both read the buffer rather than the file on disk, so an unsaved edit that
renames a test is seen — though of course only a saved, built one can
actually run. Which tests a buffer holds is worked out from the classes it
declares and the test names dotnet already listed, so a helper method or a
call to another test is never mistaken for one. When nothing in the buffer
matches a listed test, it says so and runs nothing.

Without a target, or with a directory, dtest uses a solution file in that
directory, or else the first project file there (both in name order).
`:DtestFile` and `:DtestNearest` fall back to searching upwards from the
file itself, so they work from a buffer whose project is nowhere near the
working directory. On open, the
solution is built once and each test project is listed with `dotnet test
--list-tests`. Test projects are recognised by a `Microsoft.NET.Test.Sdk`,
`Microsoft.Testing.Platform`, xUnit, NUnit, MSTest or TUnit reference, or
`<IsTestProject>true</IsTestProject>`; when a solution has none of those
every project is listed.

## Keys

Press `?` in the tree for this list, which shows whatever keys are bound.
All of them can be changed; see [Configuration](#configuration).

| Key | Action |
| --- | --- |
| `<C-j>` / `<C-k>`, `<Tab>` | Switch between the log and the tree |
| `j` / `k`, `gg` / `G`, `<C-d>` / `<C-u>` | Neovim's own motions, in whichever pane has focus |
| `V` then `y` | Neovim's own linewise visual mode, for copying out of the log |
| `l` / `h` | Expand / collapse a project, class or theory (`h` on a collapsed node selects its parent) |
| `L` / `H` | Expand / collapse the whole tree |
| `<Space>` | Toggle a fold |
| `i` / `I` | Focus on the selected project or class, treating its tests as the only ones; step back out |
| `<CR>`, `r` | Run the selected node; on the root that is the whole solution in one `dotnet test` |
| `A` | Run the whole solution, or whatever is in focus |
| `F` | Re-run only the failed tests |
| `f` / `s` | Show only the failed / skipped tests |
| `a` | Show all tests again (`<Esc>` does too) |
| `x` | Cancel the running tests and drop the queue |
| `n` / `N` | Next / previous failed test |
| `o` | Open the source: the stack frame under the log cursor, else a failed test's failing line, else the declaration |
| `t`, `/` | Filter the tree by test or project name as you type; `<CR>` keeps the filter, `<Esc>` drops it |
| `v` | Show the raw dotnet output of the selected project instead of its results |
| `<C-r>` | Rebuild and list the tests again |
| `?` | Help; any key closes it |
| `q` | Hide dtest, keeping the session (`:DtestClose` ends it) |

The tree-only keys (`l`, `h`, `n`, `N`, `/`, `f`, `s`, `a`, `i`, `t`,
`<Space>`) are bound in the tree pane alone, so the log keeps Neovim's
search and motions. Everything else works in both.

Runs use `dotnet test --filter`: `FullyQualifiedName~Ns.Class.` for a class
and `FullyQualifiedName=Ns.Class.Method` for a method. A theory row cannot
be addressed on its own, so running one runs its method. Results come from
the console logger as they happen and from the TRX files when the run ends,
so a test that was not listed (added since the last reload) still appears.

Durations are `0.032s` below a second, `1.5s` below ten, `35s` below a
minute, then `2m34s`. They are coloured as vitest colours them: green up to
300ms, yellow beyond it, so slow tests stand out, with the unit in a faded
shade of the number's own colour. A group shows the sum of its tests'
times. The summary's timer is different: it is the wall clock over the
batch, so it keeps moving through a slow test instead of sitting still
until the next result lands.

## Configuration

Everything below is a default; pass only what you want to change.

```lua
require('dtest').setup({
  target = nil,          -- solution or project file; nil looks in the cwd
  configuration = nil,   -- build configuration passed to dotnet (-c)
  no_build = false,      -- never build; list and run against existing binaries
  build_on_open = true,  -- build once when the panes open

  layout = {
    direction = 'auto',  -- 'auto' | 'vertical' (stacked) | 'horizontal' (side by side)
    position = 'auto',   -- where they are carved out of the current window:
                         -- 'auto' | 'right' | 'left' | 'below' | 'above'
    size = nil,          -- their share of that window: a fifth beside it,
                         -- two thirds under it, unless this says otherwise
    log_ratio = 0.7,     -- the log's share of the panes, the tree taking the rest
    footer = true,       -- the two summary lines along the bottom
  },

  icons = {
    passed = '✓', failed = '×', skipped = '↓', none = '·', queued = '⧗',
    arrow = '❯', open = '▾', closed = '▸', rule = '⎯',
    spinner = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' },
  },

  -- A highlight definition, or the name of a group to link to.
  colors = {
    passed  = { fg = '#87af87', ctermfg = 108 },
    failed  = { fg = '#af5f5f', ctermfg = 131 },
    skipped = { fg = '#af875f', ctermfg = 137 },
    running = { fg = '#5fafaf', ctermfg = 6 },
    dim     = { fg = '#6c6c6c', ctermfg = 8 },
    badge   = { fg = '#ffffff', ctermfg = 15 },
  },

  -- An action's list replaces its default outright, so rebinding one never
  -- disturbs another, and an empty list unbinds it.
  keys = {
    run = { '<CR>', 'r' },
    quit = { 'q', 'Q' },
    ['expand-all'] = {},
  },
})
```

The actions are `switch-pane`, `expand`, `collapse`, `expand-all`,
`collapse-all`, `toggle-fold`, `focus`, `unfocus`, `run`, `run-all`,
`run-failed`, `only-failed`, `only-skipped`, `show-all`, `clear`, `cancel`,
`next-failure`, `previous-failure`, `open-in-editor`, `filter`,
`toggle-output`, `reload`, `help` and `quit`. The help screen prints
whatever is bound, so `?` always tells the truth about your own keys.

The three outcome colours are washed shades rather than the terminal's own
red, green and yellow, which are meant to shout and would, on a screen that
is mostly results. Every other group is derived from the six above: the
tree draws each colour a shade back, so the summary is the line that
carries. The groups themselves — `DtestPassed`, `DtestFailed`,
`DtestSkipped`, `DtestRunning`, `DtestDim`, `DtestBold`, `DtestQuick`,
`DtestSlow`, `DtestExpected`, `DtestActual`, `DtestLocation`,
`DtestBadgeFail`, `DtestTreePassed` and the rest — are defined with
`default = true`, so a colourscheme or your own `:highlight` has the last
word.

The buffers carry the filetypes `dtest-tree`, `dtest-log` and
`dtest-summary`, for anything else you want to hang off them.

## Differences from the terminal dtest

Everything the editor already does well is left to the editor, so this is
not quite key for key with the TUI:

- Motions, search and copying are Neovim's own. dtest has its own log
  cursor, `V`/`y` selection and OSC 52 clipboard because a TUI must; here
  the log is a buffer, so `/`, `n`, `V`, `y` and your own mappings work in
  it. `n` and `N` are therefore bound to the next and previous failure in
  the tree pane only.
- `o` opens the file in the window dtest was opened from, rather than
  sending it to a Neovim listening on a socket. `$nvim_sock` means nothing
  here.
- The panes are windows beside your code rather than a screen of their
  own, so the summary is a window rather than a drawn footer and the two
  of them turn side by side when there is room for it.
- `:DtestFile` and `:DtestNearest` have no counterpart in the TUI, which
  has no buffer to read: dtest is driven from its own tree.
- A solution-wide run reads every `.trx` the run wrote, not one: dotnet
  gives each project its own, and naming them all the same would leave only
  the last project's messages.

## Development

```sh
make test     # nvim --headless -l tests/run.lua
```

The tests run the real session with the `dotnet` CLI stood in for
(`tests/helper.lua`), so they need neither the SDK nor a solution on disk,
and they cover the tree model, the parsers and the panes themselves.

```
plugin/dtest.lua        the user commands
lua/dtest/init.lua      setup() and the public API
lua/dtest/config.lua    defaults, key bindings, colours
lua/dtest/session.lua   the model: the queue of runs, the batch, the logs
lua/dtest/tree.lua      solution → project → class → method → case nodes
lua/dtest/context.lua   reading a source buffer: its classes, the test at the cursor
lua/dtest/pick.lua      the folder list, through Snacks' picker or vim.ui.select
lua/dtest/dotnet/       the CLI: solutions, --list-tests, runs, TRX, filters, source lookup
lua/dtest/ui/           the panes: windows, rendering, highlights, the filter prompt
```
