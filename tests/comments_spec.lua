-- UI accessors return nil once their windows close; every call below runs
-- behind a harness guard that keeps them open, which LuaLS cannot see.
---@diagnostic disable: param-type-mismatch

local comments_ui = require("agentic-flow.comments_ui")
local harness = require("tests.harness")
local pipeline = require("agentic-flow.pipeline")
local review = require("agentic-flow.review")

local assert_equal = harness.assert_equal
local assert_contains = harness.assert_contains
local config = require("agentic-flow").get_config()
config.clipboard = "a"

local root = harness.repo()
harness.write(root .. "/a.txt", { "a one", "a two", "a three" })
harness.write(root .. "/b.txt", { "b one" })
harness.write(root .. "/c.txt", { "c one", "c two" })
harness.run(root, "git", "add", ".")
harness.run(root, "git", "commit", "-m", "base")
harness.run(root, "git", "checkout", "-b", "feature")
harness.write(root .. "/a.txt", { "A one", "a two", "a three" })
harness.write(root .. "/b.txt", { "B one" })

local context = assert(harness.await(pipeline.open, config, { root = root, base = "main" }))
local inline = assert(pipeline.create_comment(context.key, {
  file = "a.txt",
  start_line = 2,
  end_line = 2,
  text = "Inline first\nInline second",
}))
local file_comment = assert(pipeline.create_comment(context.key, {
  file = "b.txt",
  text = "File first\nFile second",
}))
-- c.txt never changed: an off-diff comment, which the list shows unflagged.
local off_diff = assert(pipeline.create_comment(context.key, {
  file = "c.txt",
  start_line = 2,
  end_line = 2,
  text = "Off-diff note",
}))
assert_equal(context.by_file["c.txt"], nil, "c.txt is not part of the diff")
assert_equal(off_diff.off_diff, true, "the c.txt comment is off-diff")
context.session.files["a.txt"].comments[1].stale = true
context.session.files["gone.txt"] = {
  comments = {
    {
      id = "orphan",
      path = "gone.txt",
      text = "Orphan first",
      stale = false,
    },
  },
}

comments_ui.open(config, context)
assert_equal(comments_ui.is_open(), true, "the comments list opens")

local function lines()
  return vim.api.nvim_buf_get_lines(comments_ui.buf(), 0, -1, false)
end

local function find_line(needle)
  for index, line in ipairs(lines()) do
    if line:find(needle, 1, true) then
      return index, line
    end
  end
end

local a_line, a_text = assert(find_line("a.txt:2"))
local b_line = assert(find_line("b.txt"))
local off_diff_line, off_diff_text = assert(find_line("c.txt:2"))
local orphan_line, orphan_text = assert(find_line("gone.txt"))
assert_equal(a_line < b_line and b_line < orphan_line, true, "comments sort by file and range")
assert_equal(b_line < off_diff_line, true, "off-diff comments sort into path order")
assert_contains(a_text, "[stale]", "stale comments are labelled")
assert_contains(orphan_text, "[orphan]", "orphan comments are labelled")
assert_equal(
  off_diff_text:find("[", 1, true),
  nil,
  "off-diff comments carry no flag — nothing moved under them"
)
assert_equal(
  find_line("Inline second") ~= nil,
  true,
  "multi-line comments have an expanded preview"
)

-- Jump uses the relocated/current line and focuses the source buffer.
vim.api.nvim_win_set_cursor(comments_ui.win(), { a_line, 0 })
comments_ui.jump()
assert_equal(
  vim.b[vim.api.nvim_get_current_buf()].agentic_flow_path,
  "a.txt",
  "jump opens the file"
)
assert_equal(vim.api.nvim_win_get_cursor(0)[1], 2, "jump lands on the comment line")

-- Editing uses the acwrite float and persists through the pipeline.
vim.api.nvim_set_current_win(comments_ui.win())
vim.api.nvim_win_set_cursor(comments_ui.win(), { b_line, 0 })
local editor = comments_ui.edit()
assert_equal(vim.bo[editor].buftype, "acwrite", "editing opens an acwrite buffer")
vim.api.nvim_buf_set_lines(editor, 0, -1, false, { "Updated file note" })
vim.api.nvim_exec_autocmds("BufWriteCmd", { buffer = editor })
local updated
for _, comment in ipairs(review.comments(assert(pipeline.get(context.key)))) do
  if comment.id == file_comment.id then
    updated = comment
  end
end
assert_equal(updated.text, "Updated file note", "editing persists the changed text")

-- Delete round-trips through persistence and refreshes the list.
vim.api.nvim_set_current_win(comments_ui.win())
vim.api.nvim_win_set_cursor(comments_ui.win(), { assert(find_line("a.txt:2")), 0 })
assert(comments_ui.delete())
for _, comment in ipairs(review.comments(assert(pipeline.get(context.key)))) do
  assert_equal(comment.id ~= inline.id, true, "the selected comment is deleted")
end
assert_equal(find_line("a.txt:2"), nil, "deleted comments disappear from the list")

-- Copy uses the configured register and the stable domain output format.
local copied = assert(comments_ui.copy())
assert_equal(vim.fn.getreg("a"), copied, "copy writes the configured register")
assert_contains(copied, "@b.txt : Updated file note", "copy retains the prompt format")
assert_contains(copied, "@c.txt:2 : Off-diff note", "off-diff comments are copied too")

comments_ui.close()
assert_equal(comments_ui.is_open(), false, "the comments list closes")
pipeline.close(context.key)
print("comments_spec passed")
