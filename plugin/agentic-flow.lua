if vim.g.loaded_agentic_flow then
  return
end

vim.g.loaded_agentic_flow = true

vim.api.nvim_create_user_command("AgenticFlowChanges", function(command)
  require("agentic-flow").changes({
    base = command.args ~= "" and command.args or nil,
  })
end, {
  desc = "Review files changed from a Git comparison base",
  nargs = "?",
})

vim.api.nvim_create_user_command("AgenticFlowBase", function()
  require("agentic-flow").select_base()
end, {
  desc = "Select the Git comparison base",
})

vim.api.nvim_create_user_command("AgenticFlowToggleReviewed", function()
  require("agentic-flow").toggle_reviewed()
end, {
  desc = "Toggle reviewed state for every chunk in the current file",
})

vim.api.nvim_create_user_command("AgenticFlowToggleChunkReviewed", function()
  require("agentic-flow").toggle_chunk_reviewed()
end, {
  desc = "Toggle reviewed state for the chunk under the cursor",
})

vim.api.nvim_create_user_command("AgenticFlowNextUnreviewed", function()
  require("agentic-flow").next_unreviewed()
end, {
  desc = "Open the next unreviewed chunk",
})

vim.api.nvim_create_user_command("AgenticFlowPrevUnreviewed", function()
  require("agentic-flow").prev_unreviewed()
end, {
  desc = "Open the previous unreviewed chunk",
})

vim.api.nvim_create_user_command("AgenticFlowComment", function(command)
  local current_line = vim.api.nvim_win_get_cursor(0)[1]
  require("agentic-flow").add_comment({
    start_line = command.range > 0 and command.line1 or current_line,
    end_line = command.range > 0 and command.line2 or current_line,
  })
end, {
  desc = "Add a current-line or visual-range review comment",
  range = true,
})

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
  desc = "Copy all comments in the active review",
})
