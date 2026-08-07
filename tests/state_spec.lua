local harness = require("tests.harness")
local state = require("agentic-flow.state")

local assert_equal = harness.assert_equal
local assert_contains = harness.assert_contains

-- The state layer is keyed by an explicit storage directory; no git needed.
local storage = vim.fn.tempname()
vim.fn.mkdir(storage, "p")

-- Round-trip persistence.
local session = state.load(storage, "feature", "upstream")
assert_equal(session.version, 3, "fresh sessions should use schema v3")
assert_equal(session.files, {}, "fresh sessions should start empty")

session.files["hunks.txt"] = {
  reviewed = false,
  invalidated = false,
  reviewed_hunks = { ["abc:1"] = { reviewed_at = 1754500000 } },
  comments = {
    {
      id = "1754500000-000001",
      path = "hunks.txt",
      start_line = 2,
      end_line = 2,
      text = "note",
      anchor = { lines = { "changed hunk two" } },
      stale = false,
      created_at = 1754500000,
      updated_at = 1754500000,
    },
  },
}
session.next_comment_id = 2
assert(state.save(storage, session))
local reloaded, reload_warning = state.load(storage, "feature", "upstream")
assert_equal(reload_warning, nil, "a healthy session should load without warnings")
assert_equal(reloaded, session, "sessions should round-trip")
assert_equal(
  reloaded.files["hunks.txt"].reviewed_hunks["abc:1"].reviewed_at,
  1754500000,
  "per-hunk reviewed_at should persist"
)

-- Sessions for different keys stay separate.
local other = state.load(storage, "feature", "main")
assert_equal(other.files, {}, "sessions are keyed by (branch, base)")

-- Corrupt state: preserved as a backup, warned once (the file is moved away).
local corrupt_key = vim.fn.sha256("feature\0corrupt")
local corrupt_path = storage .. "/reviews/" .. corrupt_key .. ".json"
harness.write(corrupt_path, { "{not json" })
local _, corrupt_warning = state.load(storage, "feature", "corrupt")
assert_contains(corrupt_warning, "preserved", "corrupt state should be preserved")
assert_equal(
  #vim.fn.glob(corrupt_path .. ".corrupt.*", false, true),
  1,
  "corrupt state should be moved to a recoverable backup"
)
local _, second_warning = state.load(storage, "feature", "corrupt")
assert_equal(second_warning, nil, "the backup path should only warn once")

-- Newer schema: read-only, never overwritten.
local future_key = vim.fn.sha256("feature\0future")
local future_path = storage .. "/reviews/" .. future_key .. ".json"
harness.write(future_path, {
  vim.json.encode({ version = 99, branch = "feature", base = "future", files = {} }),
})
local future, future_warning = state.load(storage, "feature", "future")
assert_equal(future._read_only, true, "newer review schemas should be opened read-only")
assert_contains(future_warning, "unsupported schema", "newer schemas should explain the issue")
assert_equal(state.save(storage, future), false, "newer review schemas must not be overwritten")
assert_contains(
  vim.fn.readfile(future_path)[1],
  '"version":99',
  "newer state should stay intact on disk"
)

-- Older schema: preserved via the corrupt-backup path, never migrated.
local old_key = vim.fn.sha256("feature\0old")
local old_path = storage .. "/reviews/" .. old_key .. ".json"
harness.write(old_path, {
  vim.json.encode({
    version = 1,
    branch = "feature",
    base = "old",
    next_comment_id = 1,
    files = { ["hunks.txt"] = { reviewed = true, comments = {} } },
  }),
})
local old_session, old_warning = state.load(storage, "feature", "old")
assert_contains(old_warning, "preserved", "older schemas should be preserved, not migrated")
assert_equal(old_session.files, {}, "older sessions should start fresh")
assert_equal(
  #vim.fn.glob(old_path .. ".corrupt.*", false, true),
  1,
  "the old-schema file should be backed up"
)

-- Base remembering.
assert_equal(state.remembered_base(storage, "feature"), nil, "no base is remembered initially")
assert(state.remember_base(storage, "feature", "upstream"))
assert_equal(state.remembered_base(storage, "feature"), "upstream", "bases should be remembered")
assert_equal(state.remembered_base(storage, "other"), nil, "bases are remembered per branch")
-- Only explicit picks are written here, so each one must leave the others
-- alone: a guess never reaches this file at all.
assert(state.remember_base(storage, "other", "origin/main"))
assert_equal(
  { state.remembered_base(storage, "feature"), state.remembered_base(storage, "other") },
  { "upstream", "origin/main" },
  "remembering one branch's base leaves the others intact"
)

print("state_spec passed")
