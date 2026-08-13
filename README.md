# agentic-flow.nvim

A focused Neovim workflow for reviewing a branch's changes hunk by hunk,
attaching comments, and copying those comments into an agent prompt.

## Requirements

- Neovim 0.11 or newer
- Git

There are no required UI dependencies. If `mini.icons` or `nvim-web-devicons`
is installed, the sidebar borrows its file icons; neither is required.

## Setup

With `lazy.nvim`:

```lua
{
  "alzeck/agentic-flow.nvim",
  lazy = false,
  ---@module "agentic-flow"
  ---@type AgenticFlow.UserConfig
  opts = {},
  keys = {
    { "<leader>ro", "<cmd>AgenticFlowChanges<cr>", desc = "Open review sidebar" },
    { "<leader>rr", "<cmd>AgenticFlowToggleReviewed<cr>", desc = "Toggle file reviewed" },
    { "<leader>rh", "<cmd>AgenticFlowToggleHunkReviewed<cr>", desc = "Toggle hunk reviewed" },
    { "]r", "<cmd>AgenticFlowNextUnreviewed<cr>", desc = "Next unreviewed hunk" },
    { "[r", "<cmd>AgenticFlowPrevUnreviewed<cr>", desc = "Previous unreviewed hunk" },
    { "<leader>rc", "<cmd>AgenticFlowComment<cr>", mode = "n", desc = "Comment current line", },
    { "<leader>rc", ":AgenticFlowComment<cr>", mode = "x", silent = true, desc = "Comment selected lines", },
    { "<leader>rf", "<cmd>AgenticFlowFileComment<cr>", desc = "Add file comment" },
    { "<leader>rl", "<cmd>AgenticFlowComments<cr>", desc = "List review comments" },
    { "<leader>ry", "<cmd>AgenticFlowCopyComments<cr>", desc = "Copy review comments" },
    { "<leader>rb", "<cmd>AgenticFlowBase<cr>", desc = "Select review base" },
    { "<leader>rR", "<cmd>AgenticFlowRefresh<cr>", desc = "Refresh review" },
    { "<leader>rd", "<cmd>AgenticFlowDiff<cr>", desc = "Toggle review diff" },
    { "<leader>rs", "<cmd>AgenticFlowToggleSigns<cr>", desc = "Toggle review signs" },
  },
}
```

## Review workflow

Review is ambient. Opening an ordinary file buffer in a Git repository resolves
its `(repository, branch, base)` context asynchronously and attaches hunk signs
and comment markers. No command is required first.

Open the sidebar when you want the whole changed-file view:

```vim
:AgenticFlowChanges
```

The comparison starts at the merge-base with the selected base and ends at the
working tree. It includes committed branch changes, staged and unstaged changes,
renames, deletions, binary files, and untracked files.

The sidebar is one nested, collapsible tree in tree order: directories before
sibling files at every level, each group by name, a directory's contents
immediately below it. Unreviewed-hunk navigation and comment export travel the
same order, so the sidebar reads top to bottom exactly as
`AgenticFlowNextUnreviewed` moves. Files
never move when their state changes:

- pending `○`
- partial `◐ n/m`
- invalidated `↻`
- reviewed `✓`, rendered dimmed

Directories derive the same status from all changed descendants and show an
`n/m` badge. `↻` takes precedence and propagates through collapsed ancestors.
Pressing `r` on a directory marks or unmarks every changed file below it,
recursively. Unmarking more than five files asks for confirmation because review
timestamps cannot be recovered.

The sidebar behaves as a list rather than a document: a mouse wheel notch moves
the selection by `mousescroll` entries — whether or not the sidebar has focus —
and nothing scrolls past the last entry.

Files with off-diff comments appear at their normal path position with a comment
marker and no review-status glyph. They do not affect directory or title
progress.

Review state follows content-based hunk fingerprints, so unchanged hunks remain
reviewed after code moves while edited or new hunks return to review.

Tree mappings:

| Key | Action |
| --- | --- |
| `<CR>` | Open the first unreviewed hunk; retarget a sticky diff; toggle a directory |
| `r` | Toggle the selected file or directory reviewed |
| `h` | Collapse or expand a directory |
| `c` | Add a file-level comment |
| `b` | Select and remember the comparison base |
| `l` | Open the comments list |
| `y` | Copy all comments |
| `D` | Toggle sticky diff mode |
| `R` | Refresh |
| `q` | Close the sidebar |

## Signs and freshness

Changed lines use gitsigns-style extmark signs in any buffer whose context can be
resolved:

- additions: green `▎`
- modifications: blue `▎`
- deletion anchors: red `_`
- reviewed changes: dim `▎`
- comments: `●`; stale comments: `!`

`display.hunk_signs = "review_only"` limits automatic decoration to buffers
opened through the plugin. `:AgenticFlowToggleSigns` is a session kill switch:
turning it off removes all hunk and comment extmarks and stops the watcher;
turning it back on reattaches and refreshes without changing stored review state.

Review resolution and Git commands are asynchronous. The tree displays `⟳` while
a resolve is in flight. Refreshes come from:

- `BufWritePost` beneath the review root
- a debounced filesystem watcher for the worktree, Git index, HEAD, and refs
- `FocusGained`
- `R` or `:AgenticFlowRefresh`

Exactly one filesystem watcher follows the repository of the most recent
ordinary file buffer. Background contexts hold no handles or autocmds. Parsed
contexts are cached least-recently-used up to `context_cap` (default `8`);
foreground and buffer-attached contexts are never evicted.

macOS uses recursive filesystem events. libuv does not provide recursive
`fs_event` support on Linux, so Linux watches the root non-recursively and relies
on buffer writes and focus changes for nested directories.

## Sticky diff mode

Toggle the built-in before/after diff:

```vim
:AgenticFlowDiff
```

The left side is a read-only merge-base scratch and the right side is the real
working-tree buffer. Added and untracked files compare against an empty before
side; deleted files compare against an empty after side.

Diff mode is sticky: tree `<CR>` and next/previous navigation replace both buffers
inside the existing split. Review commands work on either side. Before-side
mapping from old lines to new-side hunks is intentionally experimental and may
change after real-world use.

## Comments

Add a comment to the current or selected lines:

```vim
:AgenticFlowComment
:'<,'>AgenticFlowComment
```

Add a file-level comment:

```vim
:AgenticFlowFileComment
```

The multiline Markdown editor saves with `:write` or `<C-s>`. Press `<C-y>` to
copy the comment as a single `@path:range : text` entry to the clipboard
register and close the editor without adding it to the review. Press `q` to
close an unchanged editor or `:q!` to discard edits.

Open the comments list:

```vim
:AgenticFlowComments
```

List mappings:

| Key | Action |
| --- | --- |
| `<CR>` | Jump to the relocated comment line |
| `e` | Edit |
| `d` | Delete |
| `D` | Clear all after confirmation |
| `y` | Copy all |
| `q` | Close |

Inline comments retain source context and relocate when their code moves. Unsafe
or ambiguous anchors are preserved as `[stale]`; comments whose files leave the
diff are preserved as `[orphan]`.

Comments can also be added deliberately to unchanged files. These off-diff
comments are session-scoped, unflagged, shown in the sidebar and comments list,
decorated in their source buffer, and included in copied output.

Copy output uses stable Codex file references, with blank lines between comments:

```text
@lua/agentic-flow/init.lua:12-18 : Keep this validation local.

@lua/agentic-flow/tree.lua : Consider the empty review state.
```

## Comparison base

Pick a local or remote branch without checking it out:

```vim
:AgenticFlowBase
```

The selection is remembered per current branch. With no remembered selection,
the plugin tries a configured `base`, then `origin/HEAD`, `origin/main`, and
`origin/master`. An inferred base is shown as guessed in the sidebar and is never
persisted. If nothing resolves, ambient decoration stays silent and the first
explicit command opens the base picker.

Pass a base while opening the sidebar to select and remember it. The sidebar and
gutter re-key together:

```vim
:AgenticFlowChanges origin/develop
```

The plugin reads local refs and never fetches or checks out the selected branch.

## Commands

| Command | Purpose |
| --- | --- |
| `AgenticFlowChanges [base]` | Open the review sidebar; optionally select its base |
| `AgenticFlowBase` | Select the comparison base |
| `AgenticFlowToggleReviewed` | Toggle every hunk in the current file |
| `AgenticFlowToggleHunkReviewed` | Toggle the hunk under the cursor |
| `AgenticFlowNextUnreviewed` | Navigate to the next unreviewed hunk |
| `AgenticFlowPrevUnreviewed` | Navigate to the previous unreviewed hunk |
| `AgenticFlowComment` | Add a line/range comment |
| `AgenticFlowFileComment` | Add a file-level comment |
| `AgenticFlowComments` | Open the comments list |
| `AgenticFlowCopyComments` | Copy every review comment |
| `AgenticFlowRefresh` | Refresh the current review context |
| `AgenticFlowToggleSigns` | Toggle all review decoration for this session |
| `AgenticFlowDiff` | Toggle sticky diff mode |

## Lua API

```lua
local flow = require("agentic-flow")

flow.changes({ base = "origin/develop" })
flow.select_base()
flow.toggle_reviewed()
flow.toggle_hunk_reviewed()
flow.next_unreviewed()
flow.prev_unreviewed()
flow.add_comment()
flow.comments()
flow.copy_comments({ register = "+" })
flow.refresh()
flow.toggle_signs()
flow.toggle_diff()
```

`add_comment()` also accepts `file`, `start_line`, `end_line`, `file_level`, and
`text`. Supplying `text` creates the comment directly instead of opening the
editor.

## Persistence

Review sessions use schema v3 beneath the repository path returned by:

```sh
git rev-parse --git-path agentic-flow
```

State is isolated by `(branch, base)`, written atomically, and survives Neovim
restarts and Git worktrees. Newer schemas open read-only; corrupt or older schema
files are preserved before a fresh session is created.

## Development

The development toolchain requires Neovim 0.11+, Git, Lua Language Server, and
StyLua:

```sh
make lint
make format
make test
```
