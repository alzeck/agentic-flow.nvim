if vim.g.loaded_agentic_flow then
  return
end

vim.g.loaded_agentic_flow = true

vim.api.nvim_create_user_command(
  "AgenticFlowChanges",
  ---@param command vim.api.keyset.create_user_command.command_args
  function(command)
    require("agentic-flow").changes({
      base = command.args ~= "" and command.args or nil,
    })
  end,
  {
    desc = "Open the review sidebar, optionally selecting its Git base",
    nargs = "?",
  }
)

vim.api.nvim_create_user_command("AgenticFlowBase", function()
  require("agentic-flow").select_base()
end, {
  desc = "Select the Git comparison base",
})

vim.api.nvim_create_user_command("AgenticFlowToggleReviewed", function()
  require("agentic-flow").toggle_reviewed()
end, {
  desc = "Toggle reviewed state for every hunk in the current file",
})

vim.api.nvim_create_user_command("AgenticFlowToggleHunkReviewed", function()
  require("agentic-flow").toggle_hunk_reviewed()
end, {
  desc = "Toggle the review hunk under the cursor",
})

vim.api.nvim_create_user_command("AgenticFlowNextUnreviewed", function()
  require("agentic-flow").next_unreviewed()
end, {
  desc = "Open the next unreviewed hunk",
})

vim.api.nvim_create_user_command("AgenticFlowPrevUnreviewed", function()
  require("agentic-flow").prev_unreviewed()
end, {
  desc = "Open the previous unreviewed hunk",
})

vim.api.nvim_create_user_command(
  "AgenticFlowComment",
  ---@param command vim.api.keyset.create_user_command.command_args
  function(command)
    local current_line = vim.api.nvim_win_get_cursor(0)[1]
    require("agentic-flow").add_comment({
      start_line = command.range > 0 and command.line1 or current_line,
      end_line = command.range > 0 and command.line2 or current_line,
    })
  end,
  {
    desc = "Add a current-line or visual-range review comment",
    range = true,
  }
)

vim.api.nvim_create_user_command("AgenticFlowFileComment", function()
  require("agentic-flow").add_comment({ file_level = true })
end, {
  desc = "Add a file-level review comment",
})

vim.api.nvim_create_user_command("AgenticFlowComments", function()
  require("agentic-flow").comments()
end, {
  desc = "List review comments",
})

vim.api.nvim_create_user_command("AgenticFlowCopyComments", function()
  require("agentic-flow").copy_comments()
end, {
  desc = "Copy every review comment",
})

vim.api.nvim_create_user_command("AgenticFlowRefresh", function()
  require("agentic-flow").refresh()
end, {
  desc = "Refresh the review context",
})

vim.api.nvim_create_user_command("AgenticFlowToggleSigns", function()
  require("agentic-flow").toggle_signs()
end, {
  desc = "Toggle hunk signs and comment markers for this session",
})

vim.api.nvim_create_user_command("AgenticFlowDiff", function()
  require("agentic-flow").toggle_diff()
end, {
  desc = "Toggle sticky built-in diff mode",
})
