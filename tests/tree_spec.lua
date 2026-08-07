-- UI accessors return nil once their windows close; every call below runs
-- behind a harness guard that keeps them open, which LuaLS cannot see.
---@diagnostic disable: param-type-mismatch

local harness = require("tests.harness")
local pipeline = require("agentic-flow.pipeline")
local review = require("agentic-flow.review")
local tree = require("agentic-flow.tree")

local assert_equal = harness.assert_equal
local assert_contains = harness.assert_contains
local config = require("agentic-flow").get_config()

-- Nested layout: two files under src/ (one deeper), two at the top level.
local root = harness.repo()
harness.write(root .. "/src/a.txt", { "a base" })
harness.write(root .. "/src/deep/b.txt", { "b base" })
local top_lines = {}
for index = 1, 20 do
  top_lines[index] = ("top line %d"):format(index)
end
harness.write(root .. "/top.txt", top_lines)
harness.write(root .. "/done.txt", { "done base" })
harness.write(root .. "/rename-old.txt", { "rename me" })
harness.write(root .. "/notes/caller.txt", { "unchanged caller" })
harness.run(root, "git", "add", ".")
harness.run(root, "git", "commit", "-m", "base")
harness.run(root, "git", "checkout", "-b", "feature")
harness.write(root .. "/src/a.txt", { "a changed" })
harness.write(root .. "/src/deep/b.txt", { "b changed" })
local top_changed = vim.deepcopy(top_lines)
top_changed[2] = "top changed two"
top_changed[18] = "top changed eighteen"
harness.write(root .. "/top.txt", top_changed)
harness.write(root .. "/done.txt", { "done changed" })
harness.run(root, "git", "mv", "rename-old.txt", "rename-new.txt")

tree.open(config, { root = root, base = "main" })
harness.wait(tree.is_open, "the sidebar should open")
local key = pipeline.key(root, "feature", "main")
local namespace = assert(vim.api.nvim_get_namespaces()["agentic-flow-tree"])

local function buffer_lines()
  return vim.api.nvim_buf_get_lines(tree.buf(), 0, -1, false)
end

local function find_line(needle)
  for index, line in ipairs(buffer_lines()) do
    if line:find(needle, 1, true) then
      return index, line
    end
  end
end

local function title_bar()
  return vim.wo[assert(tree.win())].winbar
end

local function count_lines(needle)
  local count = 0
  for _, line in ipairs(buffer_lines()) do
    if line:find(needle, 1, true) then
      count = count + 1
    end
  end
  return count
end

local function has_status_glyph(line)
  for _, glyph in ipairs({ "○", "◐", "↻", "✓" }) do
    if line:find(glyph, 1, true) then
      return true
    end
  end
  return false
end

---The set of highlight groups applied to one rendered line.
local function highlight_groups(line)
  local groups = {}
  local marks = vim.api.nvim_buf_get_extmarks(
    tree.buf(),
    namespace,
    { line - 1, 0 },
    { line - 1, -1 },
    { details = true }
  )
  for _, mark in ipairs(marks) do
    local group = mark[4].hl_group
    if type(group) == "number" then
      group = vim.fn.synIDattr(group, "name")
    end
    ---@cast group -nil
    groups[group] = true
  end
  return groups
end

-- Title in the winbar, one flat tree, nesting.
assert_contains(title_bar(), "Review vs main", "the winbar carries the title")
assert_contains(title_bar(), "0/5", "the title carries review progress")
assert_equal(find_line("Review vs main"), nil, "the title takes no buffer line")
assert_equal(find_line("To review"), nil, "the tree has no sections")
assert_equal(find_line("Reviewed"), nil, "the tree has no sections")
local src_line, src_text = find_line("src/")
assert_equal(src_text ~= nil, true, "directories render")
assert_contains(src_text, "○", "directories carry a derived status glyph")
assert_contains(src_text, "0/2", "directories carry an n/m badge over every file beneath them")
local _, a_text = find_line("a.txt")
assert_contains(a_text, "○", "pending files show the pending icon")
local deep_line = assert(find_line("deep/"), "nested directories render")
local b_line = assert(find_line("b.txt"))
assert_equal(src_line < deep_line and deep_line < b_line, true, "directories nest")
-- No left padding, snacks-style guides: top-level entries sit flush at the
-- left edge and nesting is drawn as guide lines, not spaces.
assert_equal(src_text:match("^%s"), nil, "top-level entries sit flush left")
assert_contains(
  select(2, assert(find_line("deep/"))),
  "├╴",
  "a followed child hangs off a branch"
)
assert_contains(
  select(2, assert(find_line("a.txt"))),
  "└╴",
  "the last child hangs off an elbow"
)
assert_contains(
  select(2, assert(find_line("b.txt"))),
  "│ └╴",
  "deeper levels extend the guides"
)
assert_equal(
  highlight_groups(b_line)["AgenticFlowTreeGuide"],
  true,
  "guides render in their own dim highlight"
)
local _, rename_text = assert(find_line("rename-new.txt"))
assert_contains(rename_text, "rename-old.txt → rename-new.txt", "renames render old → new")

-- An off-diff comment makes its unchanged file findable in tree order without
-- inventing review state for either the file or a directory containing only
-- off-diff files. The title remains progress through the diff.
local off_diff_comment = assert(pipeline.create_comment(key, {
  file = "notes/caller.txt",
  text = "This unchanged caller matters.",
}))
local notes_line, notes_text = assert(find_line("notes/"))
local caller_line, caller_text = assert(find_line("caller.txt"))
assert_equal(
  notes_line < assert(find_line("src/")) and notes_line < assert(find_line("done.txt")),
  true,
  "off-diff files share tree order with changed files"
)
assert_equal(has_status_glyph(notes_text), false, "an off-diff-only directory has no review glyph")
assert_equal(notes_text:find("%d+/%d+"), nil, "an off-diff-only directory has no progress badge")
assert_contains(caller_text, config.signs.comment, "an off-diff file renders a comment marker")
assert_equal(has_status_glyph(caller_text), false, "an off-diff file has no review-status glyph")
assert_contains(title_bar(), "0/5", "off-diff files do not count")
assert_equal(tree.node_at(caller_line).change, nil, "the off-diff node carries no fake change")

local stored_off_diff = assert(pipeline.get(key)).session.files["notes/caller.txt"].comments[1]
stored_off_diff.off_diff = false
vim.api.nvim_exec_autocmds("User", {
  pattern = "AgenticFlowContextRefreshed",
  data = { key = key, reason = "mutation" },
})
-- An orphan is still a file with comments and no diff, so it keeps its line —
-- orphans are the notes most easily lost. It is flagged rather than hidden,
-- because "the ground moved under this note" is a different claim from "I put
-- this here deliberately".
local orphan_line = assert(
  find_line("caller.txt"),
  "an orphaned comment keeps its place in the tree rather than vanishing"
)
assert_contains(
  select(2, assert(find_line("caller.txt"))),
  config.signs.stale,
  "an orphaned entry is flagged, not shown as a deliberate off-diff note"
)
assert_equal(
  assert(tree.node_at(orphan_line)).orphaned,
  true,
  "the node records that its comments were stranded"
)
stored_off_diff.off_diff = true
vim.api.nvim_exec_autocmds("User", {
  pattern = "AgenticFlowContextRefreshed",
  data = { key = key, reason = "mutation" },
})
assert(find_line("caller.txt"), "restoring the off-diff flag restores the tree entry")

assert(pipeline.delete_comment(key, off_diff_comment.id))
assert_equal(find_line("caller.txt"), nil, "deleting the last comment removes the off-diff file")
assert_equal(find_line("notes/"), nil, "empty off-diff-only directories disappear too")

-- Partial badge.
local context = assert(pipeline.get(key))
local top_hunk = assert(review.hunk_at_line(context, "top.txt", 2))
assert(pipeline.toggle_hunk(key, "top.txt", top_hunk.fingerprint))
local _, top_text = assert(find_line("top.txt"))
assert_contains(top_text, "◐", "partial files show the partial icon")
assert_contains(top_text, "1/2", "partial files show an n/m badge")

-- Folding: collapse src/, its children disappear; expand restores them.
vim.api.nvim_win_set_cursor(tree.win(), { assert(find_line("src/")), 0 })
tree.toggle_fold()
assert_equal(find_line("a.txt"), nil, "collapsed directories hide their files")
assert_equal(find_line("deep/"), nil, "collapsed directories hide nested directories")
vim.api.nvim_win_set_cursor(tree.win(), { assert(find_line("src/")), 0 })
tree.toggle_fold()
assert_equal(find_line("a.txt") ~= nil, true, "expanding restores the files")

-- <CR> on a directory has nothing to open, so it is the same fold toggle.
vim.api.nvim_win_set_cursor(tree.win(), { assert(find_line("src/")), 0 })
tree.open_entry()
assert_equal(find_line("a.txt"), nil, "<CR> collapses a directory")
vim.api.nvim_win_set_cursor(tree.win(), { assert(find_line("src/")), 0 })
tree.open_entry()
assert_equal(find_line("a.txt") ~= nil, true, "<CR> expands it back")

-- Toggling a file reviewed changes its glyph and highlight and nothing else:
-- the tree is path ordered, so no line and no cursor moves.
local done_line = assert(find_line("done.txt"))
assert_equal(
  highlight_groups(done_line)["AgenticFlowTreeDimmed"],
  nil,
  "unreviewed files are not dimmed"
)
vim.api.nvim_win_set_cursor(tree.win(), { done_line, 0 })
local before = buffer_lines()
tree.toggle_entry()
local after = buffer_lines()
assert_equal(#after, #before, "toggling reviewed leaves the tree the same size")
assert_contains(title_bar(), "1/5", "the title counter follows the toggle")
-- Every tree line but the toggled one is byte-identical.
for index = 1, #before do
  if index ~= done_line then
    assert_equal(after[index], before[index], "only the toggled file's line changes")
  end
end
assert_equal(
  after[done_line],
  (before[done_line]:gsub("○", "✓", 1)),
  "the glyph flips in place"
)
assert_equal(find_line("done.txt"), done_line, "the reviewed file keeps its line")
assert_equal(
  vim.api.nvim_win_get_cursor(tree.win())[1],
  done_line,
  "the cursor does not move on toggle"
)
local done_node = assert(tree.node_at(done_line))
assert_equal(done_node.change.file, "done.txt", "the cursor still sits on the toggled file")
---@diagnostic disable-next-line: undefined-field
assert_equal(done_node.section, nil, "nodes carry no section")
assert_equal(
  highlight_groups(done_line)["AgenticFlowTreeDimmed"],
  true,
  "reviewed files render dimmed"
)

-- One tree: every directory appears exactly once, in tree order, regardless of
-- the review state of the files under it. Directories lead their siblings and
-- each one's contents follow immediately beneath it.
assert_equal(count_lines("src/"), 1, "each directory appears exactly once")
assert_equal(count_lines("deep/"), 1, "each nested directory appears exactly once")
assert_equal(
  assert(find_line("src/")) < assert(find_line("done.txt"))
    and assert(find_line("done.txt")) < assert(find_line("rename-new.txt"))
    and assert(find_line("rename-new.txt")) < assert(find_line("top.txt")),
  true,
  "directories precede sibling files, each group by name"
)
assert_equal(
  assert(find_line("deep/")) < assert(find_line("b.txt"))
    and assert(find_line("b.txt")) < assert(find_line("a.txt")),
  true,
  "a directory's contents sit between it and its sibling files"
)

-- One order, not two: walking unreviewed hunks travels the sidebar top to
-- bottom, so the eye and `AgenticFlowNextUnreviewed` never disagree.
local first = assert(review.navigation_target(context, nil, 0, "next"))
local walked, cursor_file, cursor_line = { first.file }, first.file, first.line
for _ = 1, 20 do
  local target = assert(review.navigation_target(context, cursor_file, cursor_line, "next"))
  if target.file == first.file and target.line == first.line then
    break
  end
  cursor_file, cursor_line = target.file, target.line
  if walked[#walked] ~= target.file then
    walked[#walked + 1] = target.file
  end
end
assert_equal(#walked > 1, true, "the walk covers more than one file")
local previous = 0
for _, file in ipairs(walked) do
  local line = assert(find_line(vim.fs.basename(file)), file .. " renders in the sidebar")
  assert_equal(line > previous, true, "navigation visits files in sidebar order")
  previous = line
end

-- The last entry is the bottom of the world: scrolling — by wheel, which lands
-- as a plain scroll on whichever window the pointer is over, or by <C-e> —
-- never reveals space past the tree. The scroll is real; `WinScrolled` is
-- dispatched by hand because Neovim defers it to the main loop's pre-redraw
-- pass, which a headless `-l` script never reaches.
local tree_win = assert(tree.win())
assert_equal(vim.wo[tree_win].scrolloff, 0, "the sidebar keeps no cursor padding")
local function topline()
  return vim.api.nvim_win_call(tree_win, function()
    return vim.fn.line("w0")
  end)
end
-- `winheight()` counts text rows only: the winbar title occupies one row of
-- the window that `nvim_win_get_height` would count as scrollable.
local tree_height = vim.api.nvim_win_call(tree_win, function()
  return vim.fn.winheight(0)
end)
local highest_top = math.max(1, #buffer_lines() - tree_height + 1)
local cursor_before = vim.api.nvim_win_get_cursor(tree_win)
vim.api.nvim_win_call(tree_win, function()
  vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("20<C-e>", true, false, true))
end)
assert_equal(topline() > highest_top, true, "an unclamped scroll does run past the last entry")
vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(tree_win) })
assert_equal(topline(), highest_top, "the view is pinned back to the last entry")

-- A flicked wheel outruns WinScrolled, which Neovim raises between batches of
-- pending input rather than per keystroke; SafeState drains last and settles
-- whatever the burst left behind.
vim.api.nvim_win_call(tree_win, function()
  vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("20<C-e>", true, false, true))
end)
assert_equal(topline() > highest_top, true, "a burst can outrun the per-scroll clamp")
vim.api.nvim_exec_autocmds("SafeState", {})
assert_equal(topline(), highest_top, "the settled view rests on the last entry")

-- A wheel notch moves the selection rather than the viewport, because a list
-- scrolls by changing which item you are on. The plumbing that routes a notch
-- here is `vim.on_key` reading `getmousepos()`, which headless input never
-- reaches; what is pinned here is the movement that plumbing drives.
vim.api.nvim_win_set_cursor(tree_win, { 1, 0 })
tree.wheel(3)
assert_equal(vim.api.nvim_win_get_cursor(tree_win)[1], 4, "a notch moves the selection by its step")
tree.wheel(-3)
assert_equal(vim.api.nvim_win_get_cursor(tree_win)[1], 1, "notching back returns the selection")
tree.wheel(1000)
assert_equal(
  vim.api.nvim_win_get_cursor(tree_win)[1],
  #buffer_lines(),
  "the selection stops on the last entry"
)
vim.api.nvim_exec_autocmds("SafeState", {})
assert_equal(topline(), highest_top, "riding the wheel to the end leaves no space past it")
tree.wheel(-1000)
assert_equal(vim.api.nvim_win_get_cursor(tree_win)[1], 1, "the selection stops on the first line")
vim.api.nvim_win_set_cursor(tree_win, cursor_before)

-- Opening an entry lands in the main window at the first unreviewed hunk.
vim.api.nvim_win_set_cursor(tree.win(), { assert(find_line("top.txt")), 0 })
tree.open_entry()
harness.wait(function()
  return vim.b[vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())].agentic_flow_path
    == "top.txt"
end, "the file should open in the main window")
assert_equal(
  vim.api.nvim_get_current_win() ~= tree.win(),
  true,
  "opening focuses the main window, the sidebar stays"
)
assert_equal(vim.api.nvim_win_get_cursor(0)[1], 18, "the cursor lands on the first unreviewed hunk")

-- An active sticky diff view owns file retargeting.
local retargeted
package.loaded["agentic-flow.diff"] = {
  is_open = function()
    return true
  end,
  retarget = function(open_config, open_context, file, line)
    retargeted = {
      config = open_config,
      context = open_context,
      file = file,
      line = line,
    }
  end,
}
vim.api.nvim_win_set_cursor(tree.win(), { assert(find_line("top.txt")), 0 })
tree.open_entry()
assert_equal(retargeted.file, "top.txt", "an active diff view is retargeted")
assert_equal(retargeted.line, 18, "the diff view receives the first unreviewed hunk")
assert_equal(retargeted.config, config, "the diff view receives the tree configuration")
assert_equal(retargeted.context, pipeline.get(key), "the diff view receives the review context")
package.loaded["agentic-flow.diff"] = nil

-- Base selection goes through vim.ui.select, remembers, never checks out.
local original_select = vim.ui.select
local offered
rawset(vim.ui, "select", function(items, _opts, on_choice)
  offered = items
  for _, item in ipairs(items) do
    if item.name == "main" then
      return on_choice(item)
    end
  end
  on_choice(nil)
end)
tree.select_base()
harness.wait(function()
  return require("agentic-flow.state").remembered_base(
    assert(pipeline.get(key)).storage_dir,
    "feature"
  ) == "main"
end, "the picked base should be remembered")
rawset(vim.ui, "select", original_select)
assert_equal(offered[1].name, "feature", "the current branch sorts first in the picker")
assert_equal(harness.run(root, "git", "branch", "--show-current"), "feature", "no checkout happens")

-- Folds are keyed per context: they survive a redraw of their own context and
-- never bleed into another one.
vim.api.nvim_win_set_cursor(tree.win(), { assert(find_line("src/")), 0 })
tree.toggle_fold()
assert_equal(find_line("a.txt"), nil, "the directory collapses")
tree.refresh()
assert_equal(find_line("a.txt"), nil, "folds survive a redraw")

-- Opening another review retargets the sidebar and evicts nothing; closing
-- the sidebar closes the window only. Review is ambient: both contexts stay
-- cached until something evicts them.
local self_key = pipeline.key(root, "feature", "feature")
tree.open(config, { root = root, base = "feature" })
harness.wait(function()
  return pipeline.get(self_key) ~= nil
end, "the second review should resolve")
harness.wait(tree.is_open, "the second review should render")
assert_equal(pipeline.get(key) ~= nil, true, "opening a review leaves the previous one cached")
assert_equal(find_line("a.txt") ~= nil, true, "folds do not bleed between contexts")
tree.close()
assert_equal(tree.is_open(), false, "the sidebar closes")
assert_equal(pipeline.get(self_key) ~= nil, true, "closing the sidebar leaves the context cached")

-- Icon providers are optional: with neither installed the tree
-- renders exactly as it always has.
package.loaded["mini.icons"] = {}
package.loaded["nvim-web-devicons"] = {}
tree.open(config, { root = root, base = "main" })
harness.wait(tree.is_open, "the sidebar should reopen")
assert_equal(find_line("a.txt"), nil, "the collapsed directory is still collapsed in its context")
assert_equal(
  select(2, assert(find_line("done.txt"))),
  "✓ done.txt",
  "with no icon provider a file renders as glyph and name, flush left"
)

-- With one installed, its icon and highlight are borrowed.
local asked
package.loaded["mini.icons"] = {
  get = function(category, name)
    asked = { category = category, name = name }
    return "*", "MiniIconsAzure"
  end,
}
tree.open(config, { root = root, base = "main" })
harness.wait(tree.is_open, "the sidebar should reopen")
local icon_line, icon_text = assert(find_line("done.txt"))
assert_equal(asked.category, "file", "the provider is asked for a file icon")
assert_equal(icon_text, "✓ * done.txt", "an installed provider contributes the file icon")
assert_equal(
  highlight_groups(icon_line)["MiniIconsAzure"],
  true,
  "the provider's highlight group is used for its icon"
)
package.loaded["mini.icons"] = nil
package.loaded["nvim-web-devicons"] = nil

tree.close()
pipeline.close(self_key)
pipeline.close(key)
assert_equal(pipeline.get(key), nil, "evicting the context drops it")

-- A checkout moves the context to a new key. The sidebar follows it in place
-- rather than emptying, and carries its folds across — otherwise every checkout
-- would silently expand a tree the user had collapsed. The branches differ in
-- what they change, so a sidebar that failed to follow keeps showing the old
-- branch's file and is caught.
-- Both branches change `src/nested.txt`, so the directory exists on either
-- side and the fold assertion cannot be satisfied by content differences.
local migrate_root = harness.repo()
harness.write(migrate_root .. "/on-feature.txt", { "base" })
harness.write(migrate_root .. "/on-other.txt", { "base" })
harness.write(migrate_root .. "/src/nested.txt", { "nested base" })
harness.run(migrate_root, "git", "add", ".")
harness.run(migrate_root, "git", "commit", "-m", "base")
harness.run(migrate_root, "git", "checkout", "--quiet", "-b", "other")
harness.write(migrate_root .. "/on-other.txt", { "other changed" })
harness.write(migrate_root .. "/src/nested.txt", { "nested other" })
harness.run(migrate_root, "git", "commit", "--quiet", "-am", "other change")
harness.run(migrate_root, "git", "checkout", "--quiet", "-b", "feature", "main")
harness.write(migrate_root .. "/on-feature.txt", { "feature changed" })
harness.write(migrate_root .. "/src/nested.txt", { "nested feature" })
harness.run(migrate_root, "git", "commit", "--quiet", "-am", "feature change")

tree.open(config, { root = migrate_root, base = "main" })
local migrate_key = pipeline.key(migrate_root, "feature", "main")
harness.wait(function()
  return tree.is_open() and pipeline.get(migrate_key) ~= nil
end, "the sidebar opens on the feature context")
local function tree_text()
  return table.concat(vim.api.nvim_buf_get_lines(assert(tree.buf()), 0, -1, false), "\n")
end
assert_contains(tree_text(), "on-feature.txt", "feature's change is shown")

-- Collapse src/ so the carry-over has something to preserve.
for line = 1, #vim.api.nvim_buf_get_lines(assert(tree.buf()), 0, -1, false) do
  local node = tree.node_at(line)
  if node and node.kind == "directory" then
    vim.api.nvim_win_set_cursor(assert(tree.win()), { line, 0 })
    tree.toggle_fold()
    break
  end
end
assert_equal(
  tree_text():find("nested.txt", 1, true) == nil,
  true,
  "collapsing src/ hides the file under it"
)

local migrations = {}
vim.api.nvim_create_autocmd("User", {
  pattern = "AgenticFlowContextMigrated",
  callback = function(args)
    migrations[#migrations + 1] = args.data
  end,
})
harness.run(migrate_root, "git", "checkout", "--quiet", "other")
assert(harness.await(function(done)
  pipeline.refresh(done, migrate_key)
end))
harness.wait(function()
  return #migrations > 0
end, "the checkout migrates the context to a new key")

local migrated_text = tree_text()
assert_equal({
  migrated_text:find("on-other.txt", 1, true) ~= nil,
  migrated_text:find("on-feature.txt", 1, true),
}, { true, nil }, "the sidebar redraws from the context it moved to, not the branch it left")
assert_equal(
  migrated_text:find("nested.txt", 1, true) == nil,
  true,
  "src/ is still collapsed: folds are carried across the migration, not reset"
)

tree.close()
pipeline.close(migrations[1].to)

-- `r` on a directory is exactly `r` on every file beneath it, at any depth. The
-- fan-out is one mutation, and unmarking more than five files confirms first —
-- there is no undo, and a collapsed fold hides how many files are in range.
local mark_root = harness.repo()
for index = 1, 4 do
  harness.write(mark_root .. ("/many/f%d.txt"):format(index), { "base" })
  harness.write(mark_root .. ("/few/g%d.txt"):format(index), { "base" })
end
harness.write(mark_root .. "/many/sub/f5.txt", { "base" })
harness.write(mark_root .. "/many/sub/deeper/f6.txt", { "base" })
harness.run(mark_root, "git", "add", ".")
harness.run(mark_root, "git", "commit", "-m", "base")
harness.run(mark_root, "git", "checkout", "--quiet", "-b", "feature")
for index = 1, 4 do
  harness.write(mark_root .. ("/many/f%d.txt"):format(index), { "changed" })
  harness.write(mark_root .. ("/few/g%d.txt"):format(index), { "changed" })
end
harness.write(mark_root .. "/many/sub/f5.txt", { "changed" })
harness.write(mark_root .. "/many/sub/deeper/f6.txt", { "changed" })

tree.open(config, { root = mark_root, base = "main" })
local mark_key = pipeline.key(mark_root, "feature", "main")
harness.wait(function()
  return tree.is_open() and pipeline.get(mark_key) ~= nil
end, "the sidebar opens on the marking fixture")

local function mark_status(file)
  return review.file_status(assert(pipeline.get(mark_key)), file)
end

local mutations = 0
vim.api.nvim_create_autocmd("User", {
  group = vim.api.nvim_create_augroup("AgenticFlowTreeSpecMutations", { clear = true }),
  pattern = "AgenticFlowContextRefreshed",
  callback = function(args)
    if args.data and args.data.key == mark_key and args.data.reason == "mutation" then
      mutations = mutations + 1
    end
  end,
})

vim.api.nvim_win_set_cursor(tree.win(), { assert(find_line("many/")), 0 })
tree.toggle_entry()
assert_equal(mutations, 1, "the fan-out is one mutation, not one per file")
for _, file in ipairs({ "many/f1.txt", "many/f4.txt", "many/sub/f5.txt", "many/sub/deeper/f6.txt" }) do
  assert_equal(mark_status(file), "reviewed", "marking a directory marks every file at every depth")
end
assert_equal(mark_status("few/g1.txt"), "pending", "the fan-out stops at the marked directory")
local _, many_text = assert(find_line("many/"))
assert_contains(many_text, "✓", "a fully reviewed directory shows the reviewed glyph")
assert_contains(many_text, "6/6", "the badge counts every file beneath it")

-- Six files is over the limit: the unmark confirms, and cancelling changes
-- nothing.
local prompted
local restore_select = vim.ui.select
local answer = "Cancel"
local function stub_select(_items, opts, on_choice)
  prompted = opts.prompt
  on_choice(answer)
end
rawset(vim.ui, "select", stub_select)
vim.api.nvim_win_set_cursor(tree.win(), { assert(find_line("many/")), 0 })
tree.toggle_entry()
assert_contains(prompted, "6", "unmarking six files confirms first, naming the count")
assert_equal(mark_status("many/f1.txt"), "reviewed", "cancelling the confirmation changes nothing")

prompted, answer = nil, "Unmark"
vim.api.nvim_win_set_cursor(tree.win(), { assert(find_line("many/")), 0 })
tree.toggle_entry()
assert_equal(prompted ~= nil, true, "the confirmation is offered again")
assert_equal(
  mark_status("many/sub/deeper/f6.txt"),
  "pending",
  "confirming unmarks every file beneath, at every depth"
)

-- Four files is under the limit, and marking is never destructive.
prompted = nil
vim.api.nvim_win_set_cursor(tree.win(), { assert(find_line("few/")), 0 })
tree.toggle_entry()
assert_equal(prompted, nil, "marking never confirms")
assert_equal(
  mark_status("few/g1.txt"),
  "reviewed",
  "marking a small directory goes straight through"
)
vim.api.nvim_win_set_cursor(tree.win(), { assert(find_line("few/")), 0 })
tree.toggle_entry()
assert_equal(prompted, nil, "unmarking four files does not confirm")
assert_equal(mark_status("few/g1.txt"), "pending", "the unmark went through unprompted")
rawset(vim.ui, "select", restore_select)

-- Freshness: the status is derived, so a file appearing inside an already
-- marked directory arrives pending and returns the directory to partial.
vim.api.nvim_win_set_cursor(tree.win(), { assert(find_line("few/")), 0 })
tree.toggle_entry()
assert_contains(select(2, assert(find_line("few/"))), "✓", "few/ is fully reviewed")
harness.write(mark_root .. "/few/fresh.txt", { "fresh" })
assert(harness.await(tree.refresh))
assert_contains(
  select(2, assert(find_line("fresh.txt"))),
  "○",
  "a file entering a marked directory arrives pending"
)
local _, few_text = assert(find_line("few/"))
assert_contains(few_text, "◐", "the newcomer returns the marked directory to partial")
assert_contains(few_text, "4/5", "the badge counts the newcomer")

-- `↻` outranks every other glyph and reaches the root, so a rewrite of
-- something already signed off is visible without expanding a fold — while the
-- badge keeps reporting progress alongside it.
vim.api.nvim_win_set_cursor(tree.win(), { assert(find_line("many/")), 0 })
tree.toggle_entry()
harness.write(mark_root .. "/many/sub/deeper/f6.txt", { "rewritten" })
assert(harness.await(tree.refresh))
assert_equal(mark_status("many/sub/deeper/f6.txt"), "invalidated", "the rewritten file invalidates")
assert_contains(
  select(2, assert(find_line("deeper/"))),
  "↻",
  "the invalidated file's own directory shows the invalidated glyph"
)
assert_contains(
  select(2, assert(find_line("sub/"))),
  "↻",
  "invalidation outranks the reviewed siblings one level up"
)
local _, many_after = assert(find_line("many/"))
assert_contains(many_after, "↻", "invalidation propagates to the root of the tree")
assert_contains(many_after, "5/6", "the badge still reports progress alongside the alarm")

tree.close()
pipeline.close(mark_key)

-- When no base can be inferred, opening the sidebar is the explicit user action
-- that surfaces the problem: it opens the normal base picker instead of
-- emitting the ambient dormancy reason as an error.
local dormant_root = harness.repo()
harness.write(dormant_root .. "/tracked.txt", { "base" })
harness.run(dormant_root, "git", "add", ".")
harness.run(dormant_root, "git", "commit", "-m", "base")
harness.write(dormant_root .. "/tracked.txt", { "changed" })
local dormant_offered
local dormant_select = vim.ui.select
rawset(vim.ui, "select", function(items, _opts, on_choice)
  dormant_offered = items
  for _, item in ipairs(items) do
    if item.name == "main" then
      return on_choice(item)
    end
  end
  on_choice(nil)
end)
tree.open(config, { root = dormant_root })
local dormant_key = pipeline.key(dormant_root, "main", "main")
harness.wait(function()
  return dormant_offered ~= nil and tree.is_open() and pipeline.get(dormant_key) ~= nil
end, "an explicit sidebar open in a dormant repository should pick and resolve a base")
assert_equal(dormant_offered[1].name, "main", "the dormant sidebar uses the normal base picker")
assert_equal(
  require("agentic-flow.state").remembered_base(
    assert(pipeline.get(dormant_key)).storage_dir,
    "main"
  ),
  "main",
  "the base picked for a dormant repository is remembered"
)
rawset(vim.ui, "select", dormant_select)
tree.close()
pipeline.close(dormant_key)

print("tree_spec passed")
