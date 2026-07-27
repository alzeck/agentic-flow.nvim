# agentic-flow.nvim

A focused Neovim workflow for reviewing the current branch, attaching notes to files
or selected lines, and copying those notes into an agent prompt.

## Requirements

- Neovim with `vim.system()` support
- Git
- [snacks.nvim](https://github.com/folke/snacks.nvim) with its picker enabled

## Setup

Using `lazy.nvim`:

```lua
{
  "alzeck/agentic-flow.nvim",
  main = "agentic-flow",
  dependencies = {
    {
      "folke/snacks.nvim",
      opts = {
        picker = { enabled = true },
      },
    },
  },
  opts = {
    base = "origin/main",
    clipboard = "+",
    picker = {},
    branch_picker = {},
    comments_picker = {},
    signs = {
      comment = "●",
      stale = "!",
    },
    display = {
      virtual_text = true,
    },
  },
  keys = {
    {
      "<leader>ro",
      "<cmd>AgenticFlowChanges<cr>",
      desc = "Open code review",
    },
    {
      "<leader>rr",
      "<cmd>AgenticFlowToggleReviewed<cr>",
      desc = "Toggle file reviewed",
    },
    {
      "<leader>rc",
      "<cmd>AgenticFlowComment<cr>",
      mode = "n",
      desc = "Comment current line",
    },
    {
      "<leader>rc",
      ":AgenticFlowComment<cr>",
      mode = "x",
      desc = "Comment selected lines",
      silent = true,
    },
    {
      "<leader>rf",
      "<cmd>AgenticFlowFileComment<cr>",
      desc = "Comment current file",
    },
    {
      "<leader>rl",
      "<cmd>AgenticFlowComments<cr>",
      desc = "List review comments",
    },
    {
      "<leader>ry",
      "<cmd>AgenticFlowCopyComments<cr>",
      desc = "Copy review comments",
    },
    {
      "<leader>rb",
      "<cmd>AgenticFlowBase<cr>",
      desc = "Select review base",
    },
  },
}
```

`picker`, `branch_picker`, and `comments_picker` are merged into their corresponding
Snacks picker options. The `keys` entries are Lazy load triggers, so every mapping is
available before the plugin loads and loads it only when used.

## Review workflow

Open the review:

```vim
:AgenticFlowChanges
```

The comparison starts at the merge-base with the selected base and ends at the
working tree. It includes committed branch changes, staged changes, unstaged changes,
and untracked files.

The changes picker shows one row per file:

- `○` needs review
- `✓` reviewed
- `↻` changed since it was reviewed

Picker actions are available in the input and list windows:

| Action | Input | List |
| --- | --- | --- |
| Toggle reviewed | `<C-r>` | `r` |
| Add file note | `<C-n>` | `c` |
| Select base | `<C-b>` | `b` |
| List comments | `<C-l>` | `l` |
| Copy comments | `<C-y>` | `y` |

Press `<CR>` to open a changed file at its first changed line. Deleted files open
their base contents in a read-only buffer. Binary files support file-level notes but
not line selections.

Files are fingerprinted when marked reviewed. Any later content, status, rename, or
effective base-diff change moves the file back to review. A modified buffer must be
saved before it can be marked reviewed.

## Comparison base

Pick a local or remote branch without checking it out:

```vim
:AgenticFlowBase
```

The last selection is remembered per current branch. `base` from `setup()` is the
fallback for branches without a remembered selection.

Use a ref for one review directly:

```vim
:AgenticFlowChanges origin/develop
```

Remote refs are read locally; the plugin does not fetch them.

## Comments

Without a range, a comment applies to the current line:

```vim
:AgenticFlowComment
```

Select code in visual mode and run the same command to attach the note to the
inclusive line range:

```vim
:'<,'>AgenticFlowComment
```

Use the explicit file command for a note that applies to the whole file:

```vim
:AgenticFlowFileComment
```

A small multiline editor opens for the note. Save with `:write` or `<C-s>`. Close an
unchanged editor with `q`, or discard edits with `:q!`.

Inline comments use source context to stay attached when code moves. If the selected
code changes or no longer has one safe match, the note remains available and is
marked stale. Notes for files that leave the diff are retained and marked orphaned.

List, preview, jump to, edit, delete, or clear comments:

```vim
:AgenticFlowComments
```

| Action | Input | List |
| --- | --- | --- |
| Edit | `<C-e>` | `e` |
| Delete | `<C-d>` | `d` |
| Clear all | `<C-x>` | `D` |
| Copy all | `<C-y>` | `y` |

Clearing all comments requires confirmation. Deleting one comment is immediate.

## Prompt output

Copy every comment in the active branch/base review:

```vim
:AgenticFlowCopyComments
```

Comments are sorted by file and line range and copied to the configured `clipboard`
register. File-level notes sort before inline notes:

```text
@lua/agentic-flow/init.lua:12-18 : Extract this validation into a helper.
Keep the public error message unchanged.

@lua/agentic-flow/init.lua : Add module-level documentation.
```

The `@` prefix makes each path a Codex file reference. Blank lines separate review
items, while multiline comments remain unchanged. Stale and orphan labels are UI-only
and are not added to the copied text.

## Lazy keymaps

Mappings belong in the `keys` field of the `lazy.nvim` plugin spec, as shown in
[Setup](#setup). They are registered by Lazy rather than as side effects of
`setup()`, which keeps them available even when the plugin has not loaded yet.

| Mapping | Action |
| --- | --- |
| `<leader>ro` | Open the changed-files review |
| `<leader>rr` | Toggle reviewed |
| `<leader>rc` | Comment the current line, or the selected lines in visual mode |
| `<leader>rf` | Add a file-level comment |
| `<leader>rl` | List comments |
| `<leader>ry` | Copy comments |
| `<leader>rb` | Select the base |

Change or remove entries directly in `keys` to customize the mappings. No
`keymaps` setup option or `lazy = false` setting is needed.

## Persistence

Review sessions are versioned JSON stored beneath the repository path returned by:

```sh
git rev-parse --git-path agentic-flow
```

State is isolated by current branch and comparison base, survives Neovim restarts,
works with Git worktrees, and never appears as a tracked worktree file.

## Lua API

```lua
local review = require("agentic-flow")

review.changes({ base = "origin/develop" })
review.select_base()
review.toggle_reviewed()
review.add_comment()
review.comments()
review.copy_comments({ register = "+" })
```

`add_comment()` also accepts `file`, `start_line`, `end_line`, `file_level`, and
`text` for programmatic use. Passing `file_level = true` creates a file-level note.

## Development

The development toolchain requires
[Lua Language Server](https://luals.github.io/) and
[StyLua](https://github.com/JohnnyMorganz/StyLua) on `PATH`.

```sh
make lint
make format
make test
```

`make lint` runs Lua Language Server diagnostics and verifies StyLua formatting.
`make format` formats all plugin Lua sources.
`make test` runs the test suite in an isolated temporary Git repository.
