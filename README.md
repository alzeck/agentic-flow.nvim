# agentic-flow.nvim

A Neovim plugin for reviewing workspace changes, attaching inline or file-level
comments, and turning those comments into a prompt for an agentic coding workflow.

This project is in its initial bootstrap phase. The planned scope and implementation
status live in [features.MD](features.MD).

## Setup

Using `lazy.nvim`:

```lua
{
  "alzeck/agentic-flow.nvim",
  dependencies = {
    {
      "folke/snacks.nvim",
      opts = {
        picker = { enabled = true },
      },
    },
  },
  config = function()
    require("agentic-flow").setup({
      base = "origin/main",
      picker = {},
    })
  end,
}
```

## Changed files

Open a searchable, file-grouped diff against the configured base:

```vim
:AgenticFlowChanges
```

Override the base for one invocation:

```vim
:AgenticFlowChanges origin/develop
```

The same view is available from Lua:

```lua
require("agentic-flow").changes({ base = "origin/develop" })
```

Options under `picker` are passed to the Snacks picker, allowing its layout and
presentation to be customized.

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
`make test` runs the test suite in a headless Neovim instance.
