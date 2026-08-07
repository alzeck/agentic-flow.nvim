-- UI accessors return nil once their windows close; every call below runs
-- behind a harness guard that keeps them open, which LuaLS cannot see.
---@diagnostic disable: param-type-mismatch

local harness = require("tests.harness")
local diff = require("agentic-flow.diff")
local pipeline = require("agentic-flow.pipeline")
local review = require("agentic-flow.review")
local signs = require("agentic-flow.signs")

local assert_equal = harness.assert_equal
local config = require("agentic-flow").get_config()
local root = harness.fixture_repo()
local context = assert(harness.await(pipeline.open, config, { root = root, base = "upstream" }))

signs.setup(config)
diff.setup(config)
vim.cmd.edit(vim.fn.fnameescape(root .. "/tracked.txt"))
local original_window_count = #vim.api.nvim_tabpage_list_wins(0)

-- Modified files open as merge-base before | working-tree after.
assert(harness.await(diff.open, config, context, "tracked.txt", 1))
assert_equal(diff.is_open(), true, "the diff view opens")
local before_win = diff.before_win()
local after_win = diff.after_win()
local before_buf = vim.api.nvim_win_get_buf(before_win)
local after_buf = vim.api.nvim_win_get_buf(after_win)
assert_equal(
  vim.api.nvim_buf_get_lines(before_buf, 0, -1, false),
  { "alpha", "target", "omega" },
  "the before side shows merge-base contents"
)
assert_equal(
  vim.api.nvim_buf_get_lines(after_buf, 0, -1, false),
  { "ALPHA", "target", "omega" },
  "the after side is the working-tree buffer"
)
assert_equal(vim.bo[before_buf].readonly, true, "the before side is read-only")
assert_equal(vim.wo[before_win].diff, true, "the before window uses built-in diff mode")
assert_equal(vim.wo[after_win].diff, true, "the after window uses built-in diff mode")

-- Retargeting keeps the same split. Untracked files compare against empty.
assert(harness.await(diff.retarget, config, context, "untracked.txt", 1))
assert_equal(diff.before_win(), before_win, "retargeting reuses the before window")
assert_equal(diff.after_win(), after_win, "retargeting reuses the after window")
assert_equal(
  vim.api.nvim_buf_get_lines(diff.before_buf(), 0, -1, false),
  { "" },
  "untracked files have an empty before side"
)
assert_equal(
  vim.api.nvim_buf_get_lines(diff.after_buf(), 0, -1, false),
  { "untracked change" },
  "the untracked working file is the after side"
)

-- Deleted files compare merge-base contents against an empty after side.
assert(harness.await(diff.retarget, config, context, "deleted.txt", 1))
assert_equal(
  vim.api.nvim_buf_get_lines(diff.before_buf(), 0, -1, false),
  { "deleted base line" },
  "deleted files retain their before contents"
)
assert_equal(
  vim.api.nvim_buf_get_lines(diff.after_buf(), 0, -1, false),
  { "" },
  "deleted files have an empty after side"
)

-- Before-side review commands resolve through old-side ranges.
assert(harness.await(diff.retarget, config, context, "hunks.txt", 2))
vim.api.nvim_set_current_win(diff.before_win())
vim.api.nvim_win_set_cursor(diff.before_win(), { 2, 0 })
local first_hunk = assert(review.hunk_at_old_line(context, "hunks.txt", 2))
assert(diff.toggle_hunk())
assert_equal(
  review.hunk_reviewed(assert(pipeline.get(context.key)), "hunks.txt", first_hunk),
  true,
  "before-side toggle updates the same hunk the after side sees"
)

-- Navigation is sticky and reuses the two diff windows across files.
assert(diff.navigate("next"))
assert(diff.toggle_hunk())
local cross_file = assert(diff.navigate("next"))
assert_equal(cross_file.file ~= "hunks.txt", true, "navigation advances into the next file")
harness.wait(function()
  return vim.b[diff.after_buf()].agentic_flow_path == cross_file.file
end, "cross-file navigation should finish retargeting")
assert_equal(diff.before_win(), before_win, "navigation preserves the before window")
assert_equal(diff.after_win(), after_win, "navigation preserves the after window")
assert_equal(diff.is_open(), true, "navigation keeps diff mode active")

-- Closing removes diff mode and the scratch side, restoring one main window.
local scratch = diff.before_buf()
diff.close()
assert_equal(diff.is_open(), false, "the diff view closes")
assert_equal(#vim.api.nvim_tabpage_list_wins(0), original_window_count, "close restores one window")
assert_equal(vim.api.nvim_buf_is_valid(scratch), false, "the before scratch is wiped")

-- A checkout re-keys the context under an open diff view. The view follows the
-- key it moved to: the before side reloads against the new merge-base, and
-- commands issued here mutate the branch on disk rather than the one that left.
local swap_root = harness.repo()
harness.write(swap_root .. "/tracked.txt", { "one" })
harness.run(swap_root, "git", "add", ".")
harness.run(swap_root, "git", "commit", "-m", "one")
harness.write(swap_root .. "/tracked.txt", { "two" })
harness.run(swap_root, "git", "commit", "--quiet", "-am", "two")
harness.run(swap_root, "git", "checkout", "--quiet", "-b", "early", "HEAD~1")
harness.write(swap_root .. "/tracked.txt", { "one modified" })
harness.run(swap_root, "git", "commit", "--quiet", "-am", "early work")
harness.run(swap_root, "git", "checkout", "--quiet", "-b", "feature", "main")
harness.write(swap_root .. "/tracked.txt", { "two changed" })
harness.run(swap_root, "git", "commit", "--quiet", "-am", "feature work")

local swapped = assert(harness.await(pipeline.open, config, { root = swap_root, base = "main" }))
assert(harness.await(diff.open, config, swapped, "tracked.txt", 1))
assert_equal(
  vim.api.nvim_buf_get_lines(assert(diff.before_buf()), 0, -1, false),
  { "two" },
  "the before side starts on the feature branch's merge-base"
)

harness.run(swap_root, "git", "checkout", "--quiet", "early")
local migrated = pipeline.key(swap_root, "early", "main")
assert(harness.await(function(done)
  pipeline.refresh(done, swapped.key)
end))
harness.wait(function()
  return vim.api.nvim_buf_get_lines(assert(diff.before_buf()), 0, -1, false)[1] == "one"
end, "the diff view reloads its before side against the checked-out branch")

local hunk = assert(review.hunk_at_line(assert(pipeline.get(migrated)), "tracked.txt", 1))
vim.api.nvim_set_current_win(assert(diff.after_win()))
vim.api.nvim_win_set_cursor(diff.after_win(), { 1, 0 })
assert(diff.toggle_hunk())
assert_equal(
  review.hunk_reviewed(assert(pipeline.get(migrated)), "tracked.txt", hunk),
  true,
  "commands from the diff view mutate the context it migrated to"
)
diff.close()
pipeline.close(migrated)
pipeline.close(swapped.key)

pipeline.close(context.key)
print("diff_spec passed")
