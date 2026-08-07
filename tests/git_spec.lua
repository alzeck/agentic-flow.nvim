local harness = require("tests.harness")
local git = require("agentic-flow.git")

local assert_equal = harness.assert_equal
local root = harness.fixture_repo()

local merge_base = assert(harness.await(git.merge_base, root, "upstream"))
assert_equal(merge_base ~= "", true, "a merge-base should be resolved")

local branch = harness.await(git.branch, root)
assert_equal(branch, "feature", "the current branch should be detected")

local detected_root = assert(harness.await(git.root, root))
assert_equal(detected_root, root, "the repository root should be discovered")

local valid = harness.await(git.validate_ref, root, "upstream")
assert_equal(valid, true, "existing refs should validate")
local invalid = harness.await(git.validate_ref, root, "no-such-ref")
assert_equal(invalid, false, "missing refs should not validate")

-- Base guessing: candidates are verified in order and nothing past the winner
-- is consulted.
local first, first_index =
  harness.await(git.first_valid_ref, root, { "no-such-ref", "upstream", "main" })
assert_equal({ first, first_index }, { "upstream", 2 }, "the first verifying candidate wins")
assert_equal(
  harness.await(git.first_valid_ref, root, { "no-such-ref", "also-missing" }),
  nil,
  "a list where nothing verifies resolves to nothing"
)
assert_equal(
  harness.await(git.first_valid_ref, root, {}),
  nil,
  "an empty candidate list resolves to nothing"
)

-- One batched pass over the whole diff scope.
local changes = assert(harness.await(git.changes, root, merge_base))
local by_file = {}
local statuses = {}
for _, change in ipairs(changes) do
  by_file[change.file] = change
  statuses[change.file] = change.status
end
assert_equal(
  statuses,
  {
    ["committed.txt"] = "A",
    ["hunks.txt"] = "M",
    ["tracked.txt"] = "M",
    ["staged.txt"] = "M",
    ["deleted.txt"] = "D",
    ["rename-new.txt"] = "R",
    ["untracked.txt"] = "?",
    ["binary.dat"] = "?",
  },
  "the batched pass should cover committed, staged, unstaged, deleted, renamed, and untracked files"
)

-- Batched output must equal the hunks of a per-file diff.
for _, change in ipairs(changes) do
  if change.status ~= "?" and change.status ~= "R" then
    local per_file = harness.run(
      root,
      "git",
      "diff",
      "--no-color",
      "--no-ext-diff",
      "--binary",
      "--find-renames",
      "--unified=0",
      "--inter-hunk-context=0",
      merge_base,
      "--",
      change.file
    )
    local expected = git.parse_hunks(per_file)
    local actual_fingerprints = {}
    local expected_fingerprints = {}
    for _, hunk in ipairs(change.hunks) do
      actual_fingerprints[#actual_fingerprints + 1] = hunk.fingerprint
    end
    for _, hunk in ipairs(expected) do
      expected_fingerprints[#expected_fingerprints + 1] = hunk.fingerprint
    end
    assert_equal(
      actual_fingerprints,
      expected_fingerprints,
      ("batched hunks should match per-file hunks for %s"):format(change.file)
    )
  end
end

assert_equal(#by_file["hunks.txt"].hunks, 2, "separate diff regions should produce separate hunks")
assert_equal(
  by_file["hunks.txt"].hunks[1].changed_lines,
  { 2 },
  "hunks should record changed lines"
)
assert_equal(by_file["hunks.txt"].hunks[2].changed_lines, { 18 }, "later hunks keep their location")
assert_equal(
  by_file["hunks.txt"].hunks[1].line_kinds,
  { [2] = "change" },
  "replacement lines should be classified as changes"
)
assert_equal(by_file["deleted.txt"].hunks[1].old_changed_lines, { 1 }, "deletions record old lines")
assert_equal(
  by_file["deleted.txt"].hunks[1].deletion_sign_anchors,
  { 1 },
  "pure deletions should expose sign anchors"
)
assert_equal(by_file["binary.dat"].binary, true, "binary files should be detected")
assert_equal(#by_file["binary.dat"].hunks, 0, "binary files should remain file-level")
assert_equal(
  by_file["untracked.txt"].hunks[1].changed_lines,
  { 1 },
  "untracked files synthesize hunks"
)
assert_equal(
  by_file["untracked.txt"].hunks[1].line_kinds,
  { [1] = "add" },
  "untracked lines should be classified as additions"
)
assert_equal(by_file["committed.txt"].binary, false, "binary prose in a text diff stays textual")

-- A pure rename yields zero hunks (a rename-pathspec bug once produced a whole-file add).
assert_equal(#by_file["rename-new.txt"].hunks, 0, "a pure rename should yield zero hunks")
assert_equal(by_file["rename-new.txt"].old_file, "rename-old.txt", "renames keep the old path")

-- A rename with edits yields hunks covering only the edited lines.
local rename_root = harness.repo()
local rename_lines = {}
for index = 1, 10 do
  rename_lines[index] = ("stable line %d"):format(index)
end
harness.write(rename_root .. "/original.txt", rename_lines)
harness.run(rename_root, "git", "add", ".")
harness.run(rename_root, "git", "commit", "-m", "base")
harness.run(rename_root, "git", "checkout", "-b", "feature")
harness.run(rename_root, "git", "mv", "original.txt", "moved.txt")
local edited = vim.deepcopy(rename_lines)
edited[5] = "edited line 5"
harness.write(rename_root .. "/moved.txt", edited)
local rename_mb = assert(harness.await(git.merge_base, rename_root, "main"))
local rename_changes = assert(harness.await(git.changes, rename_root, rename_mb))
assert_equal(#rename_changes, 1, "the rename should be a single change")
assert_equal(rename_changes[1].status, "R", "an edited rename should stay a rename")
assert_equal(#rename_changes[1].hunks, 1, "an edited rename should produce one hunk")
assert_equal(
  rename_changes[1].hunks[1].changed_lines,
  { 5 },
  "rename hunks should cover only the edited lines"
)

-- Fingerprints: content-addressed with occurrence-index dedup.
local shifted =
  git.parse_hunks(table.concat({ "@@ -10,2 +20,2 @@", "-old", "+new", " context" }, "\n"))
local original =
  git.parse_hunks(table.concat({ "@@ -1,2 +1,2 @@", "-old", "+new", " context" }, "\n"))
assert_equal(
  shifted[1].fingerprint,
  original[1].fingerprint,
  "hunk fingerprints should ignore line-number movement"
)
local duplicates = git.parse_hunks(table.concat({
  "@@ -1,2 +1,2 @@",
  "-old",
  "+new",
  " context",
  "@@ -10,2 +10,2 @@",
  "-old",
  "+new",
  " context",
}, "\n"))
assert_equal(
  duplicates[1].fingerprint ~= duplicates[2].fingerprint,
  true,
  "duplicate hunk bodies should receive distinct fingerprints"
)

-- Added-versus-changed classification inside one hunk.
local mixed = git.parse_hunks(table.concat({
  "@@ -1,3 +1,4 @@",
  "-old one",
  "+new one",
  "+inserted",
  " context",
  "-removed",
}, "\n"))
assert_equal(
  mixed[1].line_kinds,
  { [1] = "change", [2] = "add" },
  "paired replacements are changes, surplus additions are adds"
)
assert_equal(
  mixed[1].old_line_kinds,
  { [1] = "change", [3] = "delete" },
  "old-side lines should classify paired changes and pure deletions"
)

-- A single unreadable file degrades that file only.
local degraded_root = harness.repo()
harness.write(degraded_root .. "/fine.txt", { "base" })
harness.run(degraded_root, "git", "add", ".")
harness.run(degraded_root, "git", "commit", "-m", "base")
harness.run(degraded_root, "git", "checkout", "-b", "feature")
harness.write(degraded_root .. "/fine.txt", { "changed" })
harness.write(degraded_root .. "/locked.txt", { "unreadable" })
assert(vim.uv.fs_chmod(degraded_root .. "/locked.txt", 0))
local degraded_mb = assert(harness.await(git.merge_base, degraded_root, "main"))
local degraded_changes = assert(harness.await(git.changes, degraded_root, degraded_mb))
local degraded_by_file = {}
for _, change in ipairs(degraded_changes) do
  degraded_by_file[change.file] = change
end
assert_equal(
  degraded_by_file["fine.txt"].hunks[1].changed_lines,
  { 1 },
  "healthy files should keep their hunks when a sibling fails"
)
assert_equal(
  degraded_by_file["locked.txt"].error ~= nil,
  true,
  "the failing file should be flagged"
)
assert_equal(#degraded_by_file["locked.txt"].hunks, 0, "the failing file should carry no hunks")
assert(vim.uv.fs_chmod(degraded_root .. "/locked.txt", 420))

-- Remaining async ports.
local branches = assert(harness.await(git.branches, root))
assert_equal(branches[1].name, "feature", "the current branch should sort first")
local names = {}
for _, entry in ipairs(branches) do
  names[entry.name] = true
end
assert_equal(names["upstream"], true, "local branches should be listed")

local storage = assert(harness.await(git.storage_dir, root))
assert_equal(
  vim.startswith(storage, root .. "/.git"),
  true,
  "storage should live under the git dir"
)

local shown = assert(harness.await(git.file_at, root, merge_base, "deleted.txt"))
assert_equal(vim.trim(shown), "deleted base line", "file_at should read the merge-base contents")

print("git_spec passed")
