local harness = require("tests.harness")
local git = require("agentic-flow.git")
local state = require("agentic-flow.state")
local review = require("agentic-flow.review")

local assert_equal = harness.assert_equal
local assert_contains = harness.assert_contains

-- The domain layer operates on an explicit context; build one the way the
-- pipeline does, without any UI.
local function build_context(root, base)
  local branch = harness.await(git.branch, root)
  local storage_dir = assert(harness.await(git.storage_dir, root))
  local merge_base = assert(harness.await(git.merge_base, root, base))
  local changes = assert(harness.await(git.changes, root, merge_base))
  local session = state.load(storage_dir, branch, base)
  local context = {
    root = root,
    branch = branch,
    base = base,
    merge_base = merge_base,
    storage_dir = storage_dir,
    changes = changes,
    by_file = {},
    session = session,
  }
  for _, change in ipairs(changes) do
    context.by_file[change.file] = change
  end
  review.sync_session(context)
  return context
end

local function read_lines(root, file)
  return vim.fn.readfile(root .. "/" .. file)
end

local root = harness.fixture_repo()
local context = build_context(root, "upstream")

-- Initial states.
assert_equal(review.file_status(context, "hunks.txt"), "pending", "fresh files are pending")
assert_equal({ review.hunk_progress(context, "hunks.txt") }, { 0, 2 }, "two hunks to review")
assert_equal({ review.progress(context) }, { 0, 8 }, "nothing reviewed initially")

-- Hunk toggles are keyed by fingerprint and record reviewed_at.
local first_hunk = context.by_file["hunks.txt"].hunks[1]
local second_hunk = context.by_file["hunks.txt"].hunks[2]
local toggled = assert(review.toggle_hunk(context, "hunks.txt", first_hunk.fingerprint))
assert_equal(toggled.status, "reviewed", "the hunk should be reviewed")
assert_equal({ toggled.reviewed, toggled.total }, { 1, 2 }, "progress should be reported")
assert_equal(review.file_status(context, "hunks.txt"), "partial", "one of two hunks is partial")
local stored = context.session.files["hunks.txt"].reviewed_hunks[first_hunk.fingerprint]
assert_equal(type(stored.reviewed_at), "number", "toggling should record reviewed_at")

-- Stale fingerprints are rejected, state untouched.
local missing, missing_error = review.toggle_hunk(context, "hunks.txt", "nope:1")
assert_equal(missing, nil, "unknown fingerprints should not toggle")
assert_contains(missing_error, "no longer part of this review", "stale toggles should explain")
assert_equal({ review.hunk_progress(context, "hunks.txt") }, { 1, 2 }, "state is untouched")

-- Completing and untoggling.
assert(review.toggle_hunk(context, "hunks.txt", second_hunk.fingerprint))
assert_equal(review.file_status(context, "hunks.txt"), "reviewed", "all hunks reviewed")
local untoggled = assert(review.toggle_hunk(context, "hunks.txt", second_hunk.fingerprint))
assert_equal(untoggled.status, "pending", "toggling back returns the hunk to review")
assert_equal(review.file_status(context, "hunks.txt"), "partial", "back to partial")

-- File toggles.
local file_toggle = assert(review.toggle_file(context, "hunks.txt"))
assert_equal(file_toggle.status, "reviewed", "file toggles review every hunk")
assert_equal({ review.hunk_progress(context, "hunks.txt") }, { 2, 2 }, "all fingerprints stored")
file_toggle = assert(review.toggle_file(context, "hunks.txt"))
assert_equal(file_toggle.status, "pending", "a second file toggle resets every hunk")

-- Binary files: no textual hunks, no line comments — decided by change data.
local binary_toggle, binary_error = review.toggle_hunk(context, "binary.dat", "any:1")
assert_equal(binary_toggle, nil, "binary files have no textual hunks")
assert_contains(binary_error, "no textual", "binary hunk toggles should explain")
local binary_file_toggle = assert(review.toggle_file(context, "binary.dat"))
assert_equal(binary_file_toggle.status, "reviewed", "binary files support file-level review")
assert(review.toggle_file(context, "binary.dat"))
local binary_comment, binary_comment_error = review.create_comment(context, {
  file = "binary.dat",
  start_line = 1,
  end_line = 1,
  text = "nope",
})
assert_equal(binary_comment, nil, "binary files reject line comments")
assert_contains(binary_comment_error, "file-level", "binary comment errors should explain")

-- Old-side resolution for the diff view's before side.
assert_equal(
  review.hunk_at_old_line(context, "hunks.txt", 2).fingerprint,
  first_hunk.fingerprint,
  "old-side lines resolve to the same hunk"
)
assert_equal(
  review.hunk_at_line(context, "deleted.txt", 1).fingerprint,
  context.by_file["deleted.txt"].hunks[1].fingerprint,
  "deleted files resolve hunks via old-side ranges"
)

-- Navigation targets are pure data.
assert(review.toggle_hunk(context, "hunks.txt", first_hunk.fingerprint))
local target = assert(review.navigation_target(context, "hunks.txt", 2, "next"))
assert_equal(target.file, "hunks.txt", "navigation finds later hunks in the same file")
assert_equal(target.line, 18, "navigation targets the hunk anchor")
local previous = assert(review.navigation_target(context, "hunks.txt", 18, "previous"))
assert_equal(previous.file, "deleted.txt", "previous navigation crosses file boundaries")
local wrapped = assert(review.navigation_target(context, "untracked.txt", 1, "next"))
assert_equal(wrapped.file, "committed.txt", "next navigation wraps to the first unreviewed hunk")

-- Fingerprint stability: editing one hunk keeps the other reviewed.
harness.write(
  root .. "/hunks.txt",
  (function()
    local lines = read_lines(root, "hunks.txt")
    lines[18] = "changed hunk eighteen again"
    return lines
  end)()
)
context = build_context(root, "upstream")
assert_equal(
  review.file_status(context, "hunks.txt"),
  "partial",
  "editing one hunk should preserve the other reviewed hunk"
)
assert_equal({ review.hunk_progress(context, "hunks.txt") }, { 1, 2 }, "only one hunk re-opens")

-- Invalidation: editing the only reviewed hunk of a partial file.
harness.write(
  root .. "/hunks.txt",
  (function()
    local lines = read_lines(root, "hunks.txt")
    lines[2] = "changed hunk two again"
    return lines
  end)()
)
context = build_context(root, "upstream")
assert_equal(
  review.file_status(context, "hunks.txt"),
  "invalidated",
  "editing the only reviewed hunk should invalidate the file"
)

-- Comments: CRUD, anchors, relocation, staleness, rendering.
local general =
  assert(review.create_comment(context, { file = "tracked.txt", text = "General note." }))
assert_equal(general.start_line, nil, "file comments carry no range")
local ranged = assert(review.create_comment(context, {
  file = "tracked.txt",
  start_line = 2,
  end_line = 2,
  text = "Keep this line.\nIt is important.",
  lines = read_lines(root, "tracked.txt"),
}))
assert_equal(ranged.anchor.lines, { "target" }, "line comments retain source context")
local committed_comment = assert(
  review.create_comment(context, { file = "committed.txt", text = "Earlier file alphabetically." })
)
assert_equal(committed_comment.id ~= ranged.id, true, "comments receive unique ids")

local rendered, rendered_count = review.render_comments(context)
assert_equal(rendered_count, 3, "all comments render")
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
  "copy renders comments in the expected quoted format"
)
local copied = assert(review.copy_comments(context, "a"))
assert_equal(vim.fn.getreg("a"), copied, "copy targets the requested register")

-- Unique relocation.
harness.write(root .. "/tracked.txt", { "header", "ALPHA", "target", "omega" })
review.relocate_comments(context, "tracked.txt", read_lines(root, "tracked.txt"))
local relocated
for _, comment in ipairs(review.comments(context)) do
  if comment.id == ranged.id then
    relocated = comment
  end
end
assert_equal(relocated.start_line, 3, "a uniquely moved line should re-anchor")
assert_equal(relocated.stale, false, "a safely re-anchored comment is not stale")

-- Staleness: no safe match keeps the comment, flagged.
harness.write(root .. "/tracked.txt", { "header", "ALPHA", "edited target", "omega" })
review.relocate_comments(context, "tracked.txt", read_lines(root, "tracked.txt"))
for _, comment in ipairs(review.comments(context)) do
  if comment.id == ranged.id then
    relocated = comment
  end
end
assert_equal(relocated.stale, true, "comments whose source changed are stale")

-- Update and delete.
local updated = assert(review.update_comment(context, { id = general.id, text = "Updated note." }))
assert_equal(updated.text, "Updated note.", "comments are editable")
assert(review.delete_comment(context, committed_comment.id))
local _, count_after_delete = review.render_comments(context)
assert_equal(count_after_delete, 2, "deleted comments disappear")

-- Rename-follow: comments and review state migrate to the new path.
-- Keep the content close to the base so git still detects the rename.
harness.write(root .. "/tracked.txt", { "alpha", "target", "omega", "appended note" })
context = build_context(root, "upstream")
harness.run(root, "git", "mv", "tracked.txt", "tracked-moved.txt")
context = build_context(root, "upstream")
assert_equal(context.session.files["tracked.txt"], nil, "the old path entry should move")
local moved_comments = {}
for _, comment in ipairs(review.comments(context)) do
  if comment.path == "tracked-moved.txt" then
    moved_comments[#moved_comments + 1] = comment
  end
end
assert_equal(#moved_comments, 2, "comments follow renames")

-- A reviewed file that leaves the diff is invalidated; comments turn orphan.
assert(review.create_comment(context, { file = "untracked.txt", text = "Orphan-to-be." }))
assert(review.toggle_file(context, "untracked.txt"))
assert(vim.uv.fs_unlink(root .. "/untracked.txt"))
context = build_context(root, "upstream")
assert_equal(
  context.session.files["untracked.txt"].invalidated,
  true,
  "files that leave the diff are invalidated"
)
local orphan
for _, comment in ipairs(review.comments(context)) do
  if comment.path == "untracked.txt" then
    orphan = comment
  end
end
assert_equal(orphan.orphan, true, "comments on departed files are flagged orphan")

-- Empty comments, and comments on paths that are in neither the diff nor the
-- working tree, are rejected.
local empty, empty_error = review.create_comment(context, { file = "hunks.txt", text = "  " })
assert_equal(empty, nil, "empty comments are rejected")
assert_contains(empty_error, "empty", "empty comment errors explain")
local foreign, foreign_error = review.create_comment(context, { file = "nope.txt", text = "hi" })
assert_equal(foreign, nil, "comments only attach to files in the repository")
assert_contains(foreign_error, "repository", "foreign comment errors explain")

-- All reviewed -> no navigation target.
for _, change in ipairs(context.changes) do
  if review.file_status(context, change.file) ~= "reviewed" then
    assert(review.toggle_file(context, change.file))
  end
end
local no_target, no_target_error = review.navigation_target(context, "hunks.txt", 1, "next")
assert_equal(no_target, nil, "navigation stops when everything is reviewed")
assert_contains(no_target_error, "no unreviewed", "completed navigation explains")

-- Off-diff comments: a repository where one file changed and its caller did
-- not. Annotating the untouched caller is a normal act, and the note it
-- leaves must never be confused with an orphan.
local off_root = harness.repo()
harness.write(off_root .. "/changed.txt", { "one", "two", "three" })
harness.write(off_root .. "/caller.txt", { "calls one", "calls two" })
harness.run(off_root, "git", "add", ".")
harness.run(off_root, "git", "commit", "-m", "base")
harness.run(off_root, "git", "checkout", "-b", "feature")
harness.write(off_root .. "/changed.txt", { "ONE", "two", "three" })
local off_context = build_context(off_root, "main")
assert_equal(off_context.by_file["caller.txt"], nil, "the untouched caller is not in the diff")

local off_diff = assert(review.create_comment(off_context, {
  file = "caller.txt",
  start_line = 2,
  end_line = 2,
  text = "This caller wants the same treatment.",
  lines = read_lines(off_root, "caller.txt"),
}))
assert_equal(off_diff.off_diff, true, "a comment on a file outside the diff is off-diff")

local function comment_by_id(ctx, id)
  for _, comment in ipairs(review.comments(ctx)) do
    if comment.id == id then
      return comment
    end
  end
end

local listed = assert(comment_by_id(off_context, off_diff.id), "off-diff comments are listed")
assert_equal(listed.orphan, false, "off-diff comments are never orphans")
assert_equal(listed.stale, false, "off-diff comments are not stale")
assert_contains(
  review.render_comments(off_context),
  "@caller.txt:2 : This caller wants the same treatment.",
  "off-diff comments are copied, with no hunks to quote"
)

-- Persisted, reloaded, and re-synced: still not flagged.
off_context = build_context(off_root, "main")
listed = assert(comment_by_id(off_context, off_diff.id), "off-diff comments survive a reload")
assert_equal(listed.orphan, false, "sync_session does not retroactively orphan off-diff comments")
assert_equal(listed.stale, false, "sync_session does not retroactively stale off-diff comments")
assert_equal(
  review.file_status(off_context, "caller.txt"),
  "pending",
  "an off-diff file with a comment carries no review state"
)

-- Anchor relocation works the same off the diff (live buffer lines, unsaved).
review.relocate_comments(off_context, "caller.txt", { "header", "calls one", "calls two" })
assert_equal(
  assert(comment_by_id(off_context, off_diff.id)).start_line,
  3,
  "off-diff anchors relocate like any other"
)

-- A comment that *loses* its diff membership is still flagged an orphan, and
-- flagging it leaves the deliberate note alone.
local departing =
  assert(review.create_comment(off_context, { file = "changed.txt", text = "Was in the diff." }))
assert_equal(departing.off_diff, false, "a comment on a changed file is not off-diff")
harness.write(off_root .. "/changed.txt", { "one", "two", "three" })
off_context = build_context(off_root, "main")
assert_equal(
  assert(comment_by_id(off_context, departing.id)).orphan,
  true,
  "a comment whose file left the diff is flagged orphan"
)
assert_equal(
  assert(comment_by_id(off_context, off_diff.id)).orphan,
  false,
  "orphaning one comment leaves the off-diff comment unflagged"
)

-- Directories are markable units carrying a **derived status**: computed from
-- their descendants on every call and never stored, which is what preserves
-- **Freshness**.
local dir_root = harness.repo()
harness.write(dir_root .. "/lib/deep/nested/x.txt", { "x base" })
harness.write(dir_root .. "/lib/deep/y.txt", { "y base" })
local z_lines = {}
for index = 1, 20 do
  z_lines[index] = ("z line %d"):format(index)
end
harness.write(dir_root .. "/lib/z.txt", z_lines)
harness.write(dir_root .. "/outside.txt", { "outside base" })
harness.run(dir_root, "git", "add", ".")
harness.run(dir_root, "git", "commit", "-m", "base")
harness.run(dir_root, "git", "checkout", "-b", "feature")
harness.write(dir_root .. "/lib/deep/nested/x.txt", { "x changed" })
harness.write(dir_root .. "/lib/deep/y.txt", { "y changed" })
local z_changed = vim.deepcopy(z_lines)
z_changed[2] = "z changed two"
z_changed[18] = "z changed eighteen"
harness.write(dir_root .. "/lib/z.txt", z_changed)
harness.write(dir_root .. "/outside.txt", { "outside changed" })

local dir_context = build_context(dir_root, "main")
local lib_files = review.directory_files(dir_context, "lib")
table.sort(lib_files)
assert_equal(
  lib_files,
  { "lib/deep/nested/x.txt", "lib/deep/y.txt", "lib/z.txt" },
  "a directory reaches every file beneath it, at any depth"
)
assert_equal(
  { review.directory_status(dir_context, "lib") },
  { "pending", 0, 3 },
  "an untouched directory is pending, badge and all"
)

-- One partially reviewed file makes the whole directory partial, even with no
-- file fully reviewed yet.
local z_hunk = assert(review.hunk_at_line(dir_context, "lib/z.txt", 2))
assert(review.toggle_hunk(dir_context, "lib/z.txt", z_hunk.fingerprint))
assert_equal(
  { review.directory_status(dir_context, "lib") },
  { "partial", 0, 3 },
  "a partially reviewed descendant makes the directory partial"
)

-- Marking fans out to every depth and never inverts: the partial file is
-- carried up to reviewed with the rest.
local marked = assert(review.toggle_directory(dir_context, "lib"))
assert_equal(marked.status, "reviewed", "marking a directory reports it reviewed")
assert_equal(#marked.files, 3, "the fan-out reports every file it touched")
for _, file in ipairs(lib_files) do
  assert_equal(review.file_status(dir_context, file), "reviewed", "marking reaches every depth")
end
assert_equal(
  { review.directory_status(dir_context, "lib/deep") },
  { "reviewed", 2, 2 },
  "nested directories derive their own status"
)
assert_equal(
  review.file_status(dir_context, "outside.txt"),
  "pending",
  "the fan-out stops at the directory"
)

-- Toggle direction: not fully reviewed marks everything, never file by file.
assert(review.toggle_file(dir_context, "lib/deep/y.txt"))
assert_equal(
  { review.directory_status(dir_context, "lib") },
  { "partial", 2, 3 },
  "unmarking one file returns the directory to partial"
)
assert(review.toggle_directory(dir_context, "lib"))
assert_equal(
  { review.directory_status(dir_context, "lib") },
  { "reviewed", 3, 3 },
  "a partial directory marks all, never inverting file by file"
)

local unmarked = assert(review.toggle_directory(dir_context, "lib"))
assert_equal(unmarked.status, "pending", "a fully reviewed directory unmarks")
assert_equal(
  { review.directory_status(dir_context, "lib") },
  { "pending", 0, 3 },
  "unmarking clears every descendant"
)

local no_files, no_files_error = review.toggle_directory(dir_context, "nope")
assert_equal(no_files, nil, "a directory with no reviewable files does not toggle")
assert_contains(no_files_error, "no files", "empty directory toggles explain")

-- Freshness: nothing is stored on the directory, so a file that appears inside
-- an already-marked one arrives pending and drops the directory to partial.
assert(review.toggle_directory(dir_context, "lib"))
harness.write(dir_root .. "/lib/deep/fresh.txt", { "fresh" })
dir_context = build_context(dir_root, "main")
assert_equal(
  review.file_status(dir_context, "lib/deep/fresh.txt"),
  "pending",
  "a file entering a marked directory arrives pending"
)
assert_equal(
  { review.directory_status(dir_context, "lib/deep") },
  { "partial", 2, 3 },
  "the newcomer returns its directory to partial"
)
assert_equal(
  { review.directory_status(dir_context, "lib") },
  { "partial", 3, 4 },
  "and every directory above it"
)

-- Invalidated outranks every other state and, because every ancestor derives
-- from the same descendants, reaches the root — badge still reporting progress.
assert(review.toggle_directory(dir_context, "lib"))
harness.write(dir_root .. "/lib/deep/nested/x.txt", { "x rewritten" })
dir_context = build_context(dir_root, "main")
assert_equal(
  review.file_status(dir_context, "lib/deep/nested/x.txt"),
  "invalidated",
  "rewriting a reviewed file invalidates it"
)
assert_equal(
  { review.directory_status(dir_context, "lib/deep/nested") },
  { "invalidated", 0, 1 },
  "the invalidated file's directory is invalidated"
)
assert_equal(
  { review.directory_status(dir_context, "lib/deep") },
  { "invalidated", 2, 3 },
  "invalidation outranks the reviewed siblings"
)
assert_equal(
  { review.directory_status(dir_context, "lib") },
  { "invalidated", 3, 4 },
  "invalidation propagates to the root, and the badge still reports n/m"
)

print("review_spec passed")
