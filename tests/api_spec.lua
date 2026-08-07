local flow = require("agentic-flow")
local harness = require("tests.harness")
local pipeline = require("agentic-flow.pipeline")
local review = require("agentic-flow.review")
local util = require("agentic-flow.util")

local assert_equal = harness.assert_equal
local config_opts = {
  base = "main",
  clipboard = "a",
  debounce_ms = 350,
  display = { virtual_text = false },
}
flow.setup(config_opts)
local config = flow.get_config()
assert_equal(config.base, "main", "setup retains the comparison base")
assert_equal(config.clipboard, "a", "setup retains the clipboard register")
assert_equal(config.debounce_ms, 350, "setup retains the debounce")
assert_equal(config.context_cap, 8, "the context cache defaults to eight entries")
assert_equal(config.signs.add, "▎", "setup preserves nested sign defaults")
assert_equal(config.display.virtual_text, false, "setup merges display overrides")
assert_equal(config.display.hunk_signs, "always", "decoration is always-on by default")
assert_equal(
  pcall(flow.setup, { display = { hunk_signs = "sometimes" } }),
  false,
  "an unknown hunk_signs mode is rejected"
)
assert_equal(pcall(flow.setup, { context_cap = 0 }), false, "a zero context cap is rejected")
assert_equal(
  pcall(flow.setup, { context_cap = 1.5 }),
  false,
  "a fractional context cap is rejected"
)
flow.setup(config_opts)

local root = harness.repo()
harness.write(root .. "/code.txt", { "base", "same" })
harness.write(root .. "/other.txt", { "other base" })
harness.run(root, "git", "add", ".")
harness.run(root, "git", "commit", "-m", "base")
harness.run(root, "git", "checkout", "-b", "feature")
harness.run(root, "git", "branch", "other-base", "main")
harness.write(root .. "/code.txt", { "changed", "same" })
harness.write(root .. "/other.txt", { "other changed" })
local context = assert(harness.await(pipeline.open, config, { root = root, base = "main" }))

local buf = vim.fn.bufadd(root .. "/code.txt")
vim.fn.bufload(buf)
vim.api.nvim_win_set_buf(0, buf)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.b[buf].agentic_flow_root = root
vim.b[buf].agentic_flow_branch = "feature"
vim.b[buf].agentic_flow_base = "main"
vim.b[buf].agentic_flow_path = "code.txt"

local toggled = assert(flow.toggle_hunk_reviewed())
assert_equal(toggled.file, "code.txt", "the public hunk toggle resolves the current buffer")
assert_equal(
  review.file_status(assert(pipeline.get(context.key)), "code.txt"),
  "reviewed",
  "the hunk toggle reaches the pipeline"
)
assert(flow.toggle_reviewed())
assert_equal(
  review.file_status(assert(pipeline.get(context.key)), "code.txt"),
  "pending",
  "the public whole-file toggle reaches the pipeline"
)

local comment = assert(flow.add_comment({ text = "API note", file_level = true }))
assert_equal(comment.path, "code.txt", "the comment API resolves the current file")
local copied = assert(flow.copy_comments())
assert_equal(vim.fn.getreg("a"), copied, "copy uses the configured register")

-- A base passed to Changes re-keys the ambient context: the sidebar, buffer
-- stamp, and gutter attachment all move together, and the explicit choice is
-- remembered for this branch.
local hunk_namespace = assert(vim.api.nvim_get_namespaces()["agentic-flow-hunks"])
harness.wait(function()
  return #vim.api.nvim_buf_get_extmarks(buf, hunk_namespace, 0, -1, {}) > 0
end, "the original context should decorate the current buffer")
flow.changes({ base = "other-base" })
local rekeyed_key = pipeline.key(root, "feature", "other-base")
harness.wait(function()
  return require("agentic-flow.tree").is_open() and pipeline.get(rekeyed_key) ~= nil
end, "Changes with a base should resolve and open the re-keyed sidebar")
assert_equal(vim.b[buf].agentic_flow_base, "other-base", "the gutter buffer follows the new base")
assert_equal(
  require("agentic-flow.state").remembered_base(
    assert(pipeline.get(rekeyed_key)).storage_dir,
    "feature"
  ),
  "other-base",
  "a base passed to Changes is remembered"
)
pipeline.close(context.key)
assert_equal(
  #vim.api.nvim_buf_get_extmarks(buf, hunk_namespace, 0, -1, {}) > 0,
  true,
  "evicting the old context leaves decoration attached to the re-keyed one"
)
require("agentic-flow.tree").close()
pipeline.close(rekeyed_key)

-- Resolved-path comparison handles buffers opened through a symlinked root.
local alias = vim.fn.tempname()
assert(vim.uv.fs_symlink(root, alias, { dir = true }))
assert_equal(
  util.relative(root, alias .. "/code.txt"),
  "code.txt",
  "relative paths compare resolved roots"
)
assert(vim.uv.fs_unlink(alias))

-- A command issued on a cold buffer completes when the context lands instead
-- of silently doing nothing and working on the second try.
local cold_root = harness.repo()
harness.write(cold_root .. "/cold.txt", { "base line", "same" })
harness.run(cold_root, "git", "add", ".")
harness.run(cold_root, "git", "commit", "-m", "base")
harness.run(cold_root, "git", "checkout", "-b", "feature")
harness.write(cold_root .. "/cold.txt", { "cold change", "same" })
vim.o.swapfile = false
vim.cmd.edit(cold_root .. "/cold.txt")
local cold_buf = vim.api.nvim_get_current_buf()
assert_equal(pipeline.buffer_context(cold_buf), nil, "the buffer's context has not resolved yet")
assert_equal(flow.toggle_reviewed(), nil, "a cold command has nothing to return yet")
harness.wait(function()
  local cold_context = pipeline.buffer_context(cold_buf)
  return cold_context ~= nil and review.file_status(cold_context, "cold.txt") == "reviewed"
end, "a command issued on a cold buffer completes once its context resolves")

-- Every command is registered on a fresh plugin load.
vim.g.loaded_agentic_flow = nil
vim.cmd.runtime("plugin/agentic-flow.lua")
for _, command in ipairs({
  "AgenticFlowChanges",
  "AgenticFlowBase",
  "AgenticFlowToggleReviewed",
  "AgenticFlowToggleHunkReviewed",
  "AgenticFlowNextUnreviewed",
  "AgenticFlowPrevUnreviewed",
  "AgenticFlowComment",
  "AgenticFlowFileComment",
  "AgenticFlowComments",
  "AgenticFlowCopyComments",
  "AgenticFlowRefresh",
  "AgenticFlowDiff",
  "AgenticFlowToggleSigns",
}) do
  assert_equal(vim.fn.exists(":" .. command), 2, command .. " is registered")
end
assert_equal(
  vim.fn.exists(":AgenticFlowToggleChunkReviewed"),
  0,
  "the old chunk command is not registered"
)

-- Comment commands preserve current-line, range, and file-level intent.
local original_add_comment = flow.add_comment
local command_opts
rawset(flow, "add_comment", function(opts)
  command_opts = opts
end)
local range_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(range_buf, 0, -1, false, { "one", "two", "three" })
vim.api.nvim_win_set_buf(0, range_buf)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd("AgenticFlowComment")
assert_equal(command_opts.start_line, 2, "comment defaults to the current line")
assert_equal(command_opts.end_line, 2, "the default comment covers one line")
vim.cmd("2,3AgenticFlowComment")
assert_equal(command_opts.start_line, 2, "range start is retained")
assert_equal(command_opts.end_line, 3, "range end is retained")
vim.cmd("AgenticFlowFileComment")
assert_equal(command_opts.file_level, true, "file comment requests file-level scope")
rawset(flow, "add_comment", original_add_comment)

print("api_spec passed")
