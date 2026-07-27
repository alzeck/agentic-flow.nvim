if vim.g.loaded_agentic_flow then
  return
end

vim.g.loaded_agentic_flow = true

vim.api.nvim_create_user_command("AgenticFlowChanges", function(command)
  require("agentic-flow").changes({
    base = command.args ~= "" and command.args or nil,
  })
end, {
  desc = "Show files changed from the configured Git base",
  nargs = "?",
})
