local picker_opts

package.preload["snacks"] = function()
  return {
    picker = {
      git_diff = function(opts)
        picker_opts = opts
        return { opts = opts }
      end,
    },
  }
end

local agentic_flow = require("agentic-flow")

assert(agentic_flow.get_config().base == "origin/main", "origin/main should be the default base")

agentic_flow.setup({
  base = "origin/develop",
  picker = {
    layout = "vertical",
  },
})

local config = agentic_flow.get_config()

assert(config.base == "origin/develop", "setup() should retain the configured base")
assert(config.picker.layout == "vertical", "setup() should retain picker configuration")

config.base = "changed"

assert(
  agentic_flow.get_config().base == "origin/develop",
  "get_config() should return a copy of the active configuration"
)

local picker = agentic_flow.changes()

assert(picker ~= nil, "changes() should return the Snacks picker")
assert(picker_opts.base == "origin/develop", "changes() should use the configured base")
assert(picker_opts.group == true, "changes() should group diff hunks by file")
assert(picker_opts.layout == "vertical", "changes() should pass through picker configuration")
assert(picker_opts.title == "Changes vs origin/develop", "changes() should describe the comparison")

agentic_flow.changes({
  base = "HEAD~1",
  picker = {
    title = "Current review",
  },
})

assert(picker_opts.base == "HEAD~1", "changes() should accept a one-off base")
assert(picker_opts.title == "Current review", "changes() should accept one-off picker options")

vim.cmd.runtime("plugin/agentic-flow.lua")
vim.cmd("AgenticFlowChanges origin/release")

assert(
  picker_opts.base == "origin/release",
  "the command argument should override the configured base"
)

print("agentic-flow.nvim tests passed")
