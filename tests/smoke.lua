local agentic_flow = require("agentic-flow")

agentic_flow.setup({
  review = {
    clipboard = "+",
  },
})

local config = agentic_flow.get_config()

assert(config.review.clipboard == "+", "setup() should retain user configuration")

config.review.clipboard = "*"

assert(
  agentic_flow.get_config().review.clipboard == "+",
  "get_config() should return a copy of the active configuration"
)

print("agentic-flow.nvim tests passed")
