local picker_calls = {}

package.preload["snacks"] = function()
  return {
    picker = {
      pick = function(opts)
        local picker = {
          opts = opts,
          closed = false,
          refreshed = false,
          main = vim.api.nvim_get_current_win(),
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
local chunk_lines = {}
for index = 1, 20 do
  chunk_lines[index] = ("chunk line %d"):format(index)
end
write(root .. "/chunks.txt", chunk_lines)
run(root, "git", "add", ".")
run(root, "git", "commit", "-m", "base")
run(root, "git", "branch", "upstream")
run(root, "git", "checkout", "-b", "feature")

write(root .. "/committed.txt", { "Binary files support file-level notes." })
run(root, "git", "add", "committed.txt")
run(root, "git", "commit", "-m", "feature commit")
write(root .. "/tracked.txt", { "ALPHA", "target", "omega" })
local changed_chunk_lines = vim.deepcopy(chunk_lines)
changed_chunk_lines[2] = "changed chunk two"
changed_chunk_lines[18] = "changed chunk eighteen"
write(root .. "/chunks.txt", changed_chunk_lines)
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
})
local sidebar_picker = assert(agentic_flow.changes({ root = root }))
assert_equal(
  sidebar_picker.opts.layout,
  { preset = "sidebar", preview = false },
  "changes should open in a sidebar by default"
)
assert_equal(sidebar_picker.opts.focus, "list", "the sidebar should focus the changed-file list")
assert_equal(sidebar_picker.opts.auto_close, false, "the sidebar should stay open while reviewing")
assert_equal(
  sidebar_picker.opts.jump,
  { close = false },
  "opening a file should preserve the review sidebar"
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
assert_equal(config.signs.unreviewed, "▎", "unreviewed chunks should have a default gutter sign")
assert_equal(
  config.display.unreviewed_chunks,
  true,
  "unreviewed chunk highlighting should be enabled by default"
)
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
assert_equal(statuses["chunks.txt"], "M", "files with multiple chunks should be included")
assert_equal(statuses["tracked.txt"], "M", "unstaged changes should be included")
assert_equal(statuses["staged.txt"], "M", "staged changes should be included")
assert_equal(statuses["deleted.txt"], "D", "deleted files should be included")
assert_equal(statuses["rename-new.txt"], "R", "renamed files should be included")
assert_equal(statuses["untracked.txt"], "?", "untracked files should be included")
assert_equal(statuses["binary.dat"], "?", "untracked binary files should be included")
assert(context.by_file["binary.dat"].binary, "binary files should be detected")
assert(not context.by_file["committed.txt"].binary, "binary prose in a text diff must stay textual")
assert_equal(#context.by_file["binary.dat"].hunks, 0, "binary files should remain file-level")
local binary_chunk, binary_chunk_error = review.toggle_chunk_reviewed(
  agentic_flow.get_config(),
  { context = context, file = "binary.dat", line = 1 }
)
assert(binary_chunk == nil, "binary files should not expose textual chunk review")
assert(
  type(binary_chunk_error) == "string" and binary_chunk_error:find("no textual", 1, true),
  "file-level-only changes should explain why chunk review is unavailable"
)
assert_equal(
  #context.by_file["chunks.txt"].hunks,
  2,
  "separate diffs should produce separate chunks"
)
assert_equal(
  context.by_file["chunks.txt"].hunks[1].changed_lines,
  { 2 },
  "chunks should record exact changed current-side lines"
)
assert_equal(
  context.by_file["chunks.txt"].hunks[2].changed_lines,
  { 18 },
  "later chunks should retain their current-side location"
)

local shifted_hunks = git.parse_hunks(table.concat({
  "@@ -10,2 +20,2 @@",
  "-old",
  "+new",
  " context",
}, "\n"))
local original_hunks = git.parse_hunks(table.concat({
  "@@ -1,2 +1,2 @@",
  "-old",
  "+new",
  " context",
}, "\n"))
assert_equal(
  shifted_hunks[1].fingerprint,
  original_hunks[1].fingerprint,
  "chunk fingerprints should ignore line-number movement"
)
local duplicate_hunks = git.parse_hunks(table.concat({
  "@@ -1,2 +1,2 @@",
  "-old",
  "+new",
  " context",
  "@@ -10,2 +10,2 @@",
  "-old",
  "+new",
  " context",
}, "\n"))
assert(
  duplicate_hunks[1].fingerprint ~= duplicate_hunks[2].fingerprint,
  "duplicate chunk bodies should receive distinct fingerprints"
)

local changes_picker = assert(agentic_flow.changes({ root = root }))
assert_equal(
  changes_picker.opts.source,
  "agentic_flow_changes",
  "changes should use the review picker"
)
assert_equal(changes_picker.opts.layout, "vertical", "changes should pass through picker options")
assert_equal(#changes_picker.opts.items, 8, "the picker should contain one item per changed file")
assert(
  changes_picker.opts.title:find("Review vs upstream", 1, true),
  "the title should show the base"
)
assert(
  changes_picker.opts.actions.agentic_toggle_reviewed,
  "the picker should expose review actions"
)
local committed_item
for _, item in ipairs(changes_picker.opts.items) do
  if item.change.file == "committed.txt" then
    committed_item = item
  end
end
assert(committed_item, "the committed file should be available in the review sidebar")
changes_picker.opts.confirm(changes_picker, committed_item)
vim.wait(1000, function()
  return vim.b.agentic_flow_path == "committed.txt"
end)
assert(not changes_picker.closed, "opening a file should keep the review sidebar open")
assert_equal(
  vim.b.agentic_flow_path,
  "committed.txt",
  "selecting a sidebar item should open it in the main window"
)

local function chunk_marks(buf)
  local namespace = vim.api.nvim_get_namespaces()["agentic-flow-chunks"]
  return vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
end

local function mark_counts(buf)
  local highlights = 0
  local signs = 0
  for _, mark in ipairs(chunk_marks(buf)) do
    local details = mark[4]
    if details.line_hl_group == "AgenticFlowUnreviewed" then
      highlights = highlights + 1
    end
    if details.sign_text then
      signs = signs + 1
    end
  end
  return highlights, signs
end

local chunks_buf =
  assert(review.open_change(agentic_flow.get_config(), context, context.by_file["chunks.txt"]))
local chunk_highlights, chunk_signs = mark_counts(chunks_buf)
assert_equal(chunk_highlights, 2, "every unreviewed chunk should tint its changed lines")
assert_equal(chunk_signs, 2, "every unreviewed chunk should receive one gutter marker")

local first_chunk = assert(agentic_flow.toggle_chunk_reviewed({
  root = root,
  base = "upstream",
  file = "chunks.txt",
  line = 2,
  buf = chunks_buf,
}))
assert_equal(first_chunk.reviewed, 1, "one chunk should be reviewed")
assert_equal(first_chunk.total, 2, "chunk progress should include every file chunk")
assert(changes_picker.refreshed, "chunk toggles should refresh the persistent review sidebar")
local refreshed_chunk_item
for _, item in ipairs(changes_picker.opts.items) do
  if item.change.file == "chunks.txt" then
    refreshed_chunk_item = item
  end
end
assert(refreshed_chunk_item, "the refreshed sidebar should retain the chunked file")
assert_equal(
  refreshed_chunk_item.review_status,
  "partial",
  "the open sidebar should receive partial state immediately"
)
context = first_chunk.context
local chunk_status, _, reviewed_hunks, hunk_count = review.file_status(context, "chunks.txt")
assert_equal(chunk_status, "partial", "partly reviewed files should expose a partial state")
assert_equal({ reviewed_hunks, hunk_count }, { 1, 2 }, "partial progress should be counted")
chunk_highlights, chunk_signs = mark_counts(chunks_buf)
assert_equal(chunk_highlights, 1, "reviewed chunks should lose their background tint")
assert_equal(chunk_signs, 1, "reviewed chunks should lose their gutter marker")
local hidden_config = agentic_flow.get_config()
hidden_config.display.unreviewed_chunks = false
require("agentic-flow.ui").attach(hidden_config, context, "chunks.txt", chunks_buf)
assert_equal(#chunk_marks(chunks_buf), 0, "chunk decoration should be configurable")
require("agentic-flow.ui").attach(agentic_flow.get_config(), context, "chunks.txt", chunks_buf)

local partial_picker = assert(agentic_flow.changes({ root = root, base = "upstream" }))
local partial_item
for _, item in ipairs(partial_picker.opts.items) do
  if item.change.file == "chunks.txt" then
    partial_item = item
  end
end
assert(partial_item, "the partial file should remain in the review sidebar")
assert_equal(partial_item.review_status, "partial", "the sidebar should retain partial state")
local partial_format = partial_picker.opts.format(partial_item)
assert_equal(partial_format[1][1], "◐ ", "partial files should use a distinct icon")
assert(
  partial_format[4][1]:find("1/2 chunks", 1, true),
  "partial rows should display reviewed chunk progress"
)

local second_chunk = assert(agentic_flow.toggle_chunk_reviewed({
  root = root,
  base = "upstream",
  file = "chunks.txt",
  line = 18,
  buf = chunks_buf,
}))
assert_equal(second_chunk.reviewed, 2, "reviewing the last chunk should complete the file")
assert_equal(
  review.file_status(second_chunk.context, "chunks.txt"),
  "reviewed",
  "all chunks complete"
)
assert_equal(#chunk_marks(chunks_buf), 0, "completed files should have no chunk decoration")

vim.api.nvim_buf_set_lines(chunks_buf, 17, 18, false, { "changed chunk eighteen again" })
vim.api.nvim_buf_call(chunks_buf, function()
  vim.cmd.write()
end)
context = assert(review.resolve(agentic_flow.get_config(), { root = root, base = "upstream" }))
chunk_status, _, reviewed_hunks, hunk_count = review.file_status(context, "chunks.txt")
assert_equal(chunk_status, "partial", "editing one reviewed chunk should preserve unchanged chunks")
assert_equal(
  { reviewed_hunks, hunk_count },
  { 1, 2 },
  "only the changed chunk should return to review"
)
require("agentic-flow.ui").attach(agentic_flow.get_config(), context, "chunks.txt", chunks_buf)

vim.api.nvim_win_set_buf(0, chunks_buf)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
local next_chunk = assert(agentic_flow.next_unreviewed({ root = root, base = "upstream" }))
assert_equal(next_chunk.file, "chunks.txt", "navigation should find later chunks in the same file")
assert_equal(vim.api.nvim_win_get_cursor(0)[1], 18, "navigation should jump to the chunk anchor")
local next_file = assert(agentic_flow.next_unreviewed({ root = root, base = "upstream" }))
assert_equal(next_file.file, "committed.txt", "navigation should continue into the next file")
local previous_chunk = assert(agentic_flow.prev_unreviewed({ root = root, base = "upstream" }))
assert_equal(previous_chunk.file, "chunks.txt", "previous navigation should cross file boundaries")
assert_equal(vim.api.nvim_win_get_cursor(0)[1], 18, "previous navigation should restore the chunk")

vim.api.nvim_buf_set_lines(chunks_buf, 17, 18, false, { "unsaved chunk edit" })
local unsaved_chunk, unsaved_error = review.toggle_chunk_reviewed(agentic_flow.get_config(), {
  root = root,
  base = "upstream",
  file = "chunks.txt",
  line = 18,
  buf = chunks_buf,
})
assert(unsaved_chunk == nil, "modified chunks should not be markable as reviewed")
assert(
  type(unsaved_error) == "string" and unsaved_error:find("save the buffer", 1, true),
  "modified chunk errors should explain how to continue"
)
vim.api.nvim_buf_set_lines(chunks_buf, 17, 18, false, { "changed chunk eighteen again" })
vim.bo[chunks_buf].modified = false

local bulk_chunks = assert(agentic_flow.toggle_reviewed({
  root = root,
  base = "upstream",
  file = "chunks.txt",
}))
assert_equal(bulk_chunks.status, "reviewed", "file toggles should review every current chunk")
assert_equal(
  { review.hunk_progress(bulk_chunks.context, "chunks.txt") },
  { 2, 2 },
  "bulk review should persist all chunk fingerprints"
)
bulk_chunks = assert(agentic_flow.toggle_reviewed({
  root = root,
  base = "upstream",
  file = "chunks.txt",
}))
assert_equal(bulk_chunks.status, "pending", "a second file toggle should reset every chunk")
assert_equal(
  { review.hunk_progress(bulk_chunks.context, "chunks.txt") },
  { 0, 2 },
  "bulk reset should clear all chunk fingerprints"
)
local wrapped_next = assert(review.navigate_unreviewed(agentic_flow.get_config(), {
  root = root,
  base = "upstream",
  file = "untracked.txt",
  line = 1,
}, "next"))
assert_equal(wrapped_next.file, "chunks.txt", "next navigation should wrap to the first chunk")
assert_equal(vim.api.nvim_win_get_cursor(0)[1], 2, "wrapped navigation should use the first anchor")
local wrapped_previous = assert(review.navigate_unreviewed(agentic_flow.get_config(), {
  context = wrapped_next.context,
  file = "chunks.txt",
  line = 2,
}, "previous"))
assert_equal(
  wrapped_previous.file,
  "untracked.txt",
  "previous navigation should wrap to the final chunk"
)
local partial_before_edit = assert(review.toggle_chunk_reviewed(agentic_flow.get_config(), {
  root = root,
  base = "upstream",
  file = "chunks.txt",
  line = 2,
  buf = chunks_buf,
}))
assert_equal(partial_before_edit.reviewed, 1, "one reviewed chunk should restore partial state")
vim.api.nvim_buf_set_lines(chunks_buf, 1, 2, false, { "changed chunk two again" })
vim.api.nvim_buf_call(chunks_buf, function()
  vim.cmd.write()
end)
context = assert(review.resolve(agentic_flow.get_config(), { root = root, base = "upstream" }))
assert_equal(
  review.file_status(context, "chunks.txt"),
  "invalidated",
  "editing the only reviewed chunk in a partial file should expose invalidation"
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
local deleted_highlights, deleted_signs = mark_counts(deleted_buf)
assert_equal(deleted_highlights, 1, "deleted-file buffers should tint changed old-side lines")
assert_equal(deleted_signs, 1, "deleted-file chunks should retain a gutter marker")

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
run(root, "git", "branch", "legacy-upstream", "upstream")
local legacy_key = vim.fn.sha256("feature\0legacy-upstream")
local legacy_path = storage_dir .. "/reviews/" .. legacy_key .. ".json"
local legacy_context =
  assert(review.resolve(agentic_flow.get_config(), { root = root, base = "legacy-upstream" }))
write(legacy_path, {
  vim.json.encode({
    version = 1,
    branch = "feature",
    base = "legacy-upstream",
    next_comment_id = 1,
    files = {
      ["chunks.txt"] = {
        comments = {},
        reviewed = true,
        fingerprint = legacy_context.by_file["chunks.txt"].fingerprint,
      },
    },
  }),
})
legacy_context =
  assert(review.resolve(agentic_flow.get_config(), { root = root, base = "legacy-upstream" }))
assert_equal(
  review.file_status(legacy_context, "chunks.txt"),
  "reviewed",
  "matching v1 file review state should migrate to reviewed chunks"
)
assert_equal(
  { review.hunk_progress(legacy_context, "chunks.txt") },
  { 2, 2 },
  "v1 migration should seed every current chunk fingerprint"
)
local migrated = assert(vim.json.decode(table.concat(vim.fn.readfile(legacy_path), "\n")))
assert_equal(migrated.version, 2, "migrated review state should use schema version 2")
assert(migrated._migrated_from == nil, "migration metadata should not be persisted")
for _, change in ipairs(legacy_context.changes) do
  if review.file_status(legacy_context, change.file) ~= "reviewed" then
    assert(review.toggle_reviewed(agentic_flow.get_config(), {
      context = legacy_context,
      file = change.file,
    }))
    legacy_context =
      assert(review.resolve(agentic_flow.get_config(), { root = root, base = "legacy-upstream" }))
  end
end
local no_chunk, no_chunk_error = review.navigate_unreviewed(
  agentic_flow.get_config(),
  { context = legacy_context, file = "chunks.txt", line = 1 },
  "next"
)
assert(no_chunk == nil, "navigation should stop when every textual chunk is reviewed")
assert(
  type(no_chunk_error) == "string" and no_chunk_error:find("no unreviewed", 1, true),
  "completed-review navigation should report that no chunks remain"
)

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
  "AgenticFlowToggleChunkReviewed",
  "AgenticFlowNextUnreviewed",
  "AgenticFlowPrevUnreviewed",
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
