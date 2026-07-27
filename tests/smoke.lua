local picker_calls = {}

package.preload["snacks"] = function()
  return {
    picker = {
      pick = function(opts)
        local picker = {
          opts = opts,
          closed = false,
          refreshed = false,
        }
        function picker:close()
          self.closed = true
        end
        function picker:refresh()
          self.refreshed = true
        end
        picker_calls[#picker_calls + 1] = picker
        return picker
      end,
    },
  }
end

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(
      ("%s\nexpected: %s\nactual: %s"):format(message, vim.inspect(expected), vim.inspect(actual))
    )
  end
end

local function run(cwd, ...)
  local command = { ... }
  local result = vim.system(command, { cwd = cwd, text = true }):wait()
  assert(
    result.code == 0,
    ("command failed: %s\n%s"):format(table.concat(command, " "), result.stderr or "")
  )
  return vim.trim(result.stdout or "")
end

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

local function write_bytes(path, contents)
  local uv = vim.uv or vim.loop
  local handle = assert(uv.fs_open(path, "w", 420))
  assert(uv.fs_write(handle, contents, 0))
  uv.fs_close(handle)
end

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
run(root, "git", "init", "-b", "main")
run(root, "git", "config", "user.email", "tests@example.com")
run(root, "git", "config", "user.name", "Agentic Flow Tests")
run(root, "git", "config", "commit.gpgsign", "false")

write(root .. "/tracked.txt", { "alpha", "target", "omega" })
write(root .. "/staged.txt", { "base" })
write(root .. "/deleted.txt", { "deleted base line" })
write(root .. "/rename-old.txt", { "rename me" })
run(root, "git", "add", ".")
run(root, "git", "commit", "-m", "base")
run(root, "git", "branch", "upstream")
run(root, "git", "checkout", "-b", "feature")

write(root .. "/committed.txt", { "Binary files support file-level notes." })
run(root, "git", "add", "committed.txt")
run(root, "git", "commit", "-m", "feature commit")
write(root .. "/tracked.txt", { "ALPHA", "target", "omega" })
write(root .. "/staged.txt", { "staged change" })
run(root, "git", "add", "staged.txt")
assert(vim.uv.fs_unlink(root .. "/deleted.txt"))
run(root, "git", "mv", "rename-old.txt", "rename-new.txt")
write(root .. "/untracked.txt", { "untracked change" })
write_bytes(root .. "/binary.dat", "before\0after")

vim.cmd.cd(vim.fn.fnameescape(root))

local agentic_flow = require("agentic-flow")
local git = require("agentic-flow.git")
local review = require("agentic-flow.review")
local state = require("agentic-flow.state")

assert_equal(agentic_flow.get_config().base, "origin/main", "origin/main should remain the default")
assert_equal(
  agentic_flow.get_config().keymaps,
  nil,
  "keymaps should be owned by the plugin manager"
)

agentic_flow.setup({
  base = "upstream",
  clipboard = "a",
  picker = { layout = "vertical" },
  comments_picker = { layout = "ivy" },
})

local config = agentic_flow.get_config()
assert_equal(config.base, "upstream", "setup should retain the configured base")
assert_equal(config.picker.layout, "vertical", "setup should retain picker configuration")
config.base = "mutated"
assert_equal(agentic_flow.get_config().base, "upstream", "get_config should return a copy")

local context =
  assert(review.resolve(agentic_flow.get_config(), { root = root, base = "upstream" }))
assert_equal(context.branch, "feature", "the current branch should be detected")
assert_equal(context.base, "upstream", "the explicit base should be used")
assert(context.merge_base ~= "", "a merge-base should be resolved")

local statuses = {}
for _, change in ipairs(context.changes) do
  statuses[change.file] = change.status
end
assert_equal(statuses["committed.txt"], "A", "committed branch changes should be included")
assert_equal(statuses["tracked.txt"], "M", "unstaged changes should be included")
assert_equal(statuses["staged.txt"], "M", "staged changes should be included")
assert_equal(statuses["deleted.txt"], "D", "deleted files should be included")
assert_equal(statuses["rename-new.txt"], "R", "renamed files should be included")
assert_equal(statuses["untracked.txt"], "?", "untracked files should be included")
assert_equal(statuses["binary.dat"], "?", "untracked binary files should be included")
assert(context.by_file["binary.dat"].binary, "binary files should be detected")
assert(not context.by_file["committed.txt"].binary, "binary prose in a text diff must stay textual")

local changes_picker = assert(agentic_flow.changes({ root = root }))
assert_equal(
  changes_picker.opts.source,
  "agentic_flow_changes",
  "changes should use the review picker"
)
assert_equal(changes_picker.opts.layout, "vertical", "changes should pass through picker options")
assert_equal(#changes_picker.opts.items, 7, "the picker should contain one item per changed file")
assert(
  changes_picker.opts.title:find("Review vs upstream", 1, true),
  "the title should show the base"
)
assert(
  changes_picker.opts.actions.agentic_toggle_reviewed,
  "the picker should expose review actions"
)

local tracked_buf = vim.fn.bufadd(root .. "/tracked.txt")
vim.bo[tracked_buf].swapfile = false
vim.fn.bufload(tracked_buf)
vim.api.nvim_win_set_buf(0, tracked_buf)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
local current_line_comment = assert(agentic_flow.add_comment({
  root = root,
  base = "upstream",
  buf = tracked_buf,
  text = "Current line note.",
}))
assert_equal(current_line_comment.start_line, 2, "a normal comment should use the current line")
assert_equal(current_line_comment.end_line, 2, "a normal comment should cover one line")
assert_equal(
  current_line_comment.anchor.lines,
  { "target" },
  "current-line comments should retain source context"
)
context = assert(review.resolve(agentic_flow.get_config(), { root = root, base = "upstream" }))
assert(
  review.delete_comment(agentic_flow.get_config(), {
    context = context,
    id = current_line_comment.id,
  }),
  "the temporary current-line comment should be removable"
)

local general = assert(agentic_flow.add_comment({
  root = root,
  base = "upstream",
  file = "tracked.txt",
  text = "General note.",
}))
assert(general.start_line == nil, "a normal comment should be file-level")

local ranged = assert(agentic_flow.add_comment({
  root = root,
  base = "upstream",
  file = "tracked.txt",
  start_line = 2,
  end_line = 2,
  text = "Keep this line.\nIt is important.",
}))
assert_equal(ranged.anchor.lines, { "target" }, "line comments should retain source context")

local committed_comment = assert(agentic_flow.add_comment({
  root = root,
  base = "upstream",
  file = "committed.txt",
  text = "Earlier file alphabetically.",
}))
assert(committed_comment.id ~= ranged.id, "comments should receive stable unique IDs")

context = assert(review.resolve(agentic_flow.get_config(), { root = root, base = "upstream" }))
local rendered, rendered_count = review.render_comments(context)
assert_equal(rendered_count, 3, "all comments should be rendered")
assert_equal(
  rendered,
  table.concat({
    "@committed.txt : Earlier file alphabetically.",
    "",
    "@tracked.txt : General note.",
    "",
    "@tracked.txt:2 : Keep this line.",
    "It is important.",
  }, "\n"),
  "comments should use stable Codex file references"
)
assert_equal(
  agentic_flow.copy_comments({ root = root, base = "upstream" }),
  rendered,
  "copy should return output"
)
assert_equal(vim.fn.getreg("a"), rendered, "copy should target the configured register")

local comments_picker = assert(agentic_flow.comments({ root = root, base = "upstream" }))
assert_equal(
  comments_picker.opts.source,
  "agentic_flow_comments",
  "comments should use a dedicated picker"
)
assert_equal(comments_picker.opts.layout, "ivy", "comments picker options should pass through")
assert_equal(#comments_picker.opts.items, 3, "all comments should be listed")
assert(comments_picker.opts.actions.agentic_delete_comment, "comments should be removable")
assert(comments_picker.opts.actions.agentic_edit_comment, "comments should be editable")

local reviewed = assert(agentic_flow.toggle_reviewed({
  root = root,
  base = "upstream",
  file = "tracked.txt",
}))
assert_equal(reviewed.status, "reviewed", "files should be markable as reviewed")
context = assert(review.resolve(agentic_flow.get_config(), { root = root, base = "upstream" }))
assert_equal(review.file_status(context, "tracked.txt"), "reviewed", "review state should persist")

write(root .. "/tracked.txt", { "header", "ALPHA", "target", "omega" })
context = assert(review.resolve(agentic_flow.get_config(), { root = root, base = "upstream" }))
assert_equal(
  review.file_status(context, "tracked.txt"),
  "invalidated",
  "changed reviewed files should return to review"
)
local relocated = review.comments(context)
local ranged_after_move
for _, comment in ipairs(relocated) do
  if comment.id == ranged.id then
    ranged_after_move = comment
  end
end
assert_equal(ranged_after_move.start_line, 3, "a uniquely moved line should be re-anchored")
assert_equal(ranged_after_move.stale, false, "a safely re-anchored comment should not be stale")

write(root .. "/tracked.txt", { "header", "ALPHA", "edited target", "omega" })
context = assert(review.resolve(agentic_flow.get_config(), { root = root, base = "upstream" }))
local stale
for _, comment in ipairs(review.comments(context)) do
  if comment.id == ranged.id then
    stale = comment
  end
end
assert_equal(stale.stale, true, "comments whose source changed should be marked stale")

local updated = assert(review.update_comment(agentic_flow.get_config(), {
  context = context,
  id = general.id,
  text = "Updated general note.",
}))
assert_equal(updated.text, "Updated general note.", "comments should be editable")
assert(
  review.delete_comment(agentic_flow.get_config(), {
    context = context,
    id = committed_comment.id,
  }),
  "comments should be deletable"
)

local deleted_buf =
  assert(review.open_change(agentic_flow.get_config(), context, context.by_file["deleted.txt"]))
assert_equal(
  vim.api.nvim_buf_get_lines(deleted_buf, 0, -1, false),
  { "deleted base line" },
  "deleted files should open their base contents"
)
assert(vim.bo[deleted_buf].readonly, "deleted-file buffers should be read-only")

local branch_before = git.branch(root)
assert(
  state.remembered_base(root, "feature") == nil,
  "one-off base overrides should not replace the remembered base"
)
local base_picker = assert(agentic_flow.select_base({ context = context }))
assert_equal(base_picker.opts.source, "agentic_flow_bases", "base selection should use a picker")
local upstream_item
for _, item in ipairs(base_picker.opts.items) do
  if item.branch.name == "upstream" then
    upstream_item = item
  end
end
assert(upstream_item, "local branches should be available as comparison bases")
base_picker.opts.confirm(base_picker, upstream_item)
vim.wait(1000, function()
  return #picker_calls > 3
end)
assert_equal(git.branch(root), branch_before, "selecting a base must not check it out")
assert_equal(
  state.remembered_base(root, "feature"),
  "upstream",
  "base selection should be remembered"
)

local storage_dir = assert(git.storage_dir(root))
local corrupt_key = vim.fn.sha256("feature\0corrupt")
local corrupt_path = storage_dir .. "/reviews/" .. corrupt_key .. ".json"
write(corrupt_path, { "{not json" })
local _, corrupt_warning = state.load(root, "feature", "corrupt")
assert(
  type(corrupt_warning) == "string" and corrupt_warning:find("preserved", 1, true),
  "corrupt state should be preserved"
)
assert_equal(
  #vim.fn.glob(corrupt_path .. ".corrupt.*", false, true),
  1,
  "corrupt state should be moved to a recoverable backup"
)

local future_key = vim.fn.sha256("feature\0future")
local future_path = storage_dir .. "/reviews/" .. future_key .. ".json"
write(future_path, {
  vim.json.encode({
    version = 99,
    branch = "feature",
    base = "future",
    files = {},
  }),
})
local future, future_warning = state.load(root, "feature", "future")
assert(future._read_only, "newer review schemas should be opened read-only")
assert(
  type(future_warning) == "string" and future_warning:find("unsupported schema", 1, true),
  "newer schemas should explain the issue"
)
assert(not state.save(root, future), "newer review schemas must not be overwritten")
assert(
  vim.fn.readfile(future_path)[1]:find('"version":99', 1, true),
  "newer state should be intact"
)

local saved_editor_text
local editor_buf = require("agentic-flow.ui").comment_editor({
  label = "tracked.txt",
  text = "Draft",
  on_save = function(text)
    saved_editor_text = text
    return true
  end,
})
vim.api.nvim_buf_set_lines(editor_buf, 0, -1, false, { "First line", "Second line" })
vim.api.nvim_buf_call(editor_buf, function()
  vim.cmd.write()
end)
assert_equal(
  saved_editor_text,
  "First line\nSecond line",
  "the multiline editor should save its text"
)

vim.g.loaded_agentic_flow = nil
vim.cmd.runtime("plugin/agentic-flow.lua")
for _, command in ipairs({
  "AgenticFlowChanges",
  "AgenticFlowBase",
  "AgenticFlowToggleReviewed",
  "AgenticFlowComment",
  "AgenticFlowFileComment",
  "AgenticFlowComments",
  "AgenticFlowCopyComments",
}) do
  assert(vim.fn.exists(":" .. command) == 2, command .. " should be registered")
end

local original_add_comment = agentic_flow.add_comment
local command_range
agentic_flow.add_comment = function(opts)
  command_range = opts
end
local range_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(range_buf, 0, -1, false, { "one", "two", "three" })
vim.api.nvim_win_set_buf(0, range_buf)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd("AgenticFlowComment")
assert_equal(command_range.start_line, 2, "the comment command should default to the current line")
assert_equal(command_range.end_line, 2, "the default comment command should cover one line")
vim.cmd("2,3AgenticFlowComment")
assert_equal(command_range.start_line, 2, "the comment command should preserve visual range start")
assert_equal(command_range.end_line, 3, "the comment command should preserve visual range end")
vim.cmd("AgenticFlowFileComment")
assert(command_range.file_level, "the file comment command should request file-level scope")
agentic_flow.add_comment = original_add_comment

assert_equal(
  vim.fn.maparg("<leader>rc", "n"),
  "",
  "setup should leave keymap registration to the plugin manager"
)

print("agentic-flow.nvim tests passed")
