local harness = require("tests.harness")
local pipeline = require("agentic-flow.pipeline")
local review = require("agentic-flow.review")
local signs = require("agentic-flow.signs")

local assert_equal = harness.assert_equal
local assert_contains = harness.assert_contains
local flow = require("agentic-flow")
local config = flow.get_config()

-- A dedicated repo with two nearby changes plus a well-separated addition
-- and deletion. Nearby visible change clusters must remain separate review
-- hunks even when Git's default context would coalesce them.
local root = harness.repo()
local lines = {}
for index = 1, 30 do
  lines[index] = ("line %d"):format(index)
end
harness.write(root .. "/code.txt", lines)
harness.write(root .. "/gone.txt", { "gone line" })
harness.write(root .. "/untouched.txt", { "caller one", "caller two" })
harness.run(root, "git", "add", ".")
harness.run(root, "git", "commit", "-m", "base")
harness.run(root, "git", "checkout", "-b", "feature")
local edited = vim.deepcopy(lines)
edited[2] = "changed line 2"
edited[6] = "changed line 6"
table.insert(edited, 16, "inserted line")
table.remove(edited, 26) -- old line 25
harness.write(root .. "/code.txt", edited)
assert(vim.uv.fs_unlink(root .. "/gone.txt"))

signs.setup(config)
local context = assert(harness.await(pipeline.open, config, { root = root, base = "main" }))

local buf = vim.fn.bufadd(root .. "/code.txt")
vim.bo[buf].swapfile = false
vim.fn.bufload(buf)
signs.attach(config, context, "code.txt", buf)
assert_equal(#context.by_file["code.txt"].hunks, 4, "nearby change clusters stay separate hunks")

local function marks_by_line(target, namespace)
  local ns = vim.api.nvim_get_namespaces()[namespace]
  local found = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(target, ns, 0, -1, { details = true })) do
    local details = mark[4]
    ---@cast details -nil
    if details.sign_text then
      found[mark[2] + 1] = {
        text = vim.trim(details.sign_text),
        group = details.sign_hl_group,
      }
    end
  end
  return found
end

-- Unreviewed: add / change / deletion-anchor signs on exactly the changed lines.
assert_equal(marks_by_line(buf, "agentic-flow-hunks"), {
  [2] = { text = "▎", group = "AgenticFlowChange" },
  [6] = { text = "▎", group = "AgenticFlowChange" },
  [16] = { text = "▎", group = "AgenticFlowAdd" },
  [25] = { text = "_", group = "AgenticFlowDelete" },
}, "each changed line gets a kind-classified sign; deletions mark their anchor")

-- Toggling one hunk collapses it to the dim reviewed sign without touching others.
local first = assert(review.hunk_at_line(context, "code.txt", 2))
assert(pipeline.toggle_hunk(context.key, "code.txt", first.fingerprint))
assert_equal(marks_by_line(buf, "agentic-flow-hunks"), {
  [2] = { text = "▎", group = "AgenticFlowReviewedSign" },
  [6] = { text = "▎", group = "AgenticFlowChange" },
  [16] = { text = "▎", group = "AgenticFlowAdd" },
  [25] = { text = "_", group = "AgenticFlowDelete" },
}, "a reviewed hunk collapses to the dim sign; other hunks keep their kinds")

-- Reviewed deletions collapse their anchors too.
local deletion = assert(review.hunk_at_line(context, "code.txt", 25))
assert(pipeline.toggle_hunk(context.key, "code.txt", deletion.fingerprint))
assert_equal(
  marks_by_line(buf, "agentic-flow-hunks")[25],
  { text = "▎", group = "AgenticFlowReviewedSign" },
  "reviewed deletion anchors swap the underscore for the dim sign"
)

-- Comment signs, and stale flagging through relocation.
assert(pipeline.create_comment(context.key, {
  file = "code.txt",
  start_line = 5,
  end_line = 5,
  text = "Watch this line.",
  lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
}))
signs.attach(config, context, "code.txt", buf)
local comment_marks = marks_by_line(buf, "agentic-flow-comments")
assert_equal(
  comment_marks[5],
  { text = "●", group = "AgenticFlowComment" },
  "comments get an info sign at their line"
)
vim.api.nvim_buf_set_lines(buf, 4, 5, false, { "smashed" })
signs.attach(config, context, "code.txt", buf)
comment_marks = marks_by_line(buf, "agentic-flow-comments")
assert_equal(
  comment_marks[5],
  { text = "!", group = "AgenticFlowStale" },
  "a comment whose anchor is gone shows the stale sign"
)
vim.api.nvim_buf_set_lines(buf, 4, 5, false, { "line 5" })
vim.bo[buf].modified = false

-- Sign priority sits above gitsigns' default of 6.
local ns = vim.api.nvim_get_namespaces()["agentic-flow-hunks"]
local first_mark = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })[1]
assert_equal(first_mark[4].priority > 6, true, "hunk signs outrank gitsigns' default priority")

-- Before-side decoration uses old-side line data.
local before_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(before_buf, 0, -1, false, { "gone line" })
signs.attach(config, context, "gone.txt", before_buf, "before")
assert_equal(
  marks_by_line(before_buf, "agentic-flow-hunks")[1],
  { text = "▎", group = "AgenticFlowDelete" },
  "before-side buffers mark removed lines via old-side kinds"
)

-- Off-diff comments decorate a buffer that has no change entry at all.
assert_equal(context.by_file["untouched.txt"], nil, "the untouched file is not in the diff")
local off_buf = vim.fn.bufadd(root .. "/untouched.txt")
vim.bo[off_buf].swapfile = false
vim.fn.bufload(off_buf)
assert(pipeline.create_comment(context.key, {
  file = "untouched.txt",
  start_line = 2,
  end_line = 2,
  text = "Off the diff, on purpose.",
  lines = vim.api.nvim_buf_get_lines(off_buf, 0, -1, false),
}))
signs.attach(config, context, "untouched.txt", off_buf)
assert_equal(
  marks_by_line(off_buf, "agentic-flow-comments")[2],
  { text = "●", group = "AgenticFlowComment" },
  "a file with comments but no hunks still gets its comment sign"
)
assert_equal(
  marks_by_line(off_buf, "agentic-flow-hunks"),
  {},
  "an off-diff file has no hunk signs to show"
)

-- The engine re-decorates on context refresh events.
local hidden = assert(review.hunk_at_line(context, "code.txt", 16))
assert(pipeline.toggle_hunk(context.key, "code.txt", hidden.fingerprint))
assert_equal(
  marks_by_line(buf, "agentic-flow-hunks")[16],
  { text = "▎", group = "AgenticFlowReviewedSign" },
  "mutation events re-decorate attached buffers"
)

-- Evicting the context removes every mark everywhere.
pipeline.close(context.key)
assert_equal(marks_by_line(buf, "agentic-flow-hunks"), {}, "eviction clears hunk signs")
assert_equal(marks_by_line(buf, "agentic-flow-comments"), {}, "eviction clears comment signs")
assert_equal(
  marks_by_line(before_buf, "agentic-flow-hunks"),
  {},
  "eviction clears before-side signs"
)

-- Ambient decoration: a buffer nobody opened through the plugin.
local function extmark_count(namespace)
  local ns = vim.api.nvim_get_namespaces()[namespace]
  local total = 0
  for _, target in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(target) then
      total = total + #vim.api.nvim_buf_get_extmarks(target, ns, 0, -1, {})
    end
  end
  return total
end

vim.o.swapfile = false
vim.api.nvim_buf_delete(buf, { force = true })
vim.api.nvim_buf_delete(off_buf, { force = true })
flow.setup({ base = "main" })
local ambient_config = flow.get_config()
assert_equal(ambient_config.display.hunk_signs, "always", "decoration is always-on by default")
context = assert(harness.await(pipeline.open, ambient_config, { root = root, base = "main" }))

vim.cmd.edit(root .. "/code.txt")
local ambient_buf = vim.api.nvim_get_current_buf()
harness.wait(function()
  return marks_by_line(ambient_buf, "agentic-flow-hunks")[6] ~= nil
end, "opening a changed file with :e decorates it with no prior command")
assert_equal(
  marks_by_line(ambient_buf, "agentic-flow-hunks")[6],
  { text = "▎", group = "AgenticFlowChange" },
  "an ambient buffer signs its hunks exactly as one opened through the plugin"
)

vim.cmd.edit(root .. "/untouched.txt")
local ambient_off_buf = vim.api.nvim_get_current_buf()
harness.wait(function()
  return marks_by_line(ambient_off_buf, "agentic-flow-comments")[2] ~= nil
end, "ambient decoration reaches comment markers on a file with no diff entry")

-- The kill switch: zero marks in both namespaces, no watcher, and a lossless
-- round trip back.
local watch = require("agentic-flow.watch")
local status_before = review.file_status(assert(pipeline.get(context.key)), "code.txt")
assert_equal(flow.toggle_signs(false), false, "the kill switch reports the state it left")
assert_equal(extmark_count("agentic-flow-hunks"), 0, "the kill switch leaves no hunk extmarks")
assert_equal(
  extmark_count("agentic-flow-comments"),
  0,
  "the kill switch leaves no comment extmarks"
)
assert_equal(watch.active_key(), nil, "the kill switch stops the watcher")
vim.cmd.buffer(ambient_buf)
vim.cmd.buffer(ambient_off_buf)
vim.wait(ambient_config.debounce_ms * 2)
assert_equal(
  watch.active_key(),
  nil,
  "buffer switches cannot restart the watcher while decoration is disabled"
)
local panel_buf = vim.api.nvim_create_buf(false, true)
vim.bo[panel_buf].buftype = "nofile"
vim.api.nvim_set_current_buf(panel_buf)

assert_equal(flow.toggle_signs(true), true, "flipping the kill switch back reports it")
harness.wait(function()
  return extmark_count("agentic-flow-hunks") > 0 and extmark_count("agentic-flow-comments") > 0
end, "flipping the kill switch back restores decoration")
harness.wait(function()
  return watch.active_key() ~= nil
end, "flipping the kill switch back restarts the watcher")
assert_equal(
  review.file_status(assert(pipeline.get(context.key)), "code.txt"),
  status_before,
  "the kill switch round trip leaves stored review state untouched"
)
vim.api.nvim_buf_delete(panel_buf, { force = true })

-- review_only restores the old behaviour: only buffers the plugin opened.
flow.setup({ base = "main", display = { hunk_signs = "review_only" } })
local review_only_config = flow.get_config()
vim.api.nvim_buf_delete(ambient_buf, { force = true })
vim.cmd.edit(root .. "/code.txt")
local review_only_buf = vim.api.nvim_get_current_buf()
vim.wait(200)
assert_equal(
  marks_by_line(review_only_buf, "agentic-flow-hunks"),
  {},
  "review_only leaves a file opened with :e undecorated"
)
signs.attach(review_only_config, assert(pipeline.get(context.key)), "code.txt", review_only_buf)
assert_equal(
  marks_by_line(review_only_buf, "agentic-flow-hunks")[6],
  { text = "▎", group = "AgenticFlowChange" },
  "review_only still decorates a buffer the plugin opens itself"
)

-- A dormant repository — nothing to guess a base from — stays silent on the
-- ambient path, and speaks only when a command asks.
flow.setup({})
local dormant_root = harness.repo()
harness.write(dormant_root .. "/dormant.txt", { "one", "two" })
harness.run(dormant_root, "git", "add", ".")
harness.run(dormant_root, "git", "commit", "-m", "base")
harness.write(dormant_root .. "/dormant.txt", { "one", "changed" })

local notifications = {}
local original_notify = vim.notify
-- rawset so the stub is not a second definition of vim.notify for the linter.
rawset(vim, "notify", function(message, level)
  notifications[#notifications + 1] = { message = message, level = level }
end)

vim.cmd.edit(dormant_root .. "/dormant.txt")
local dormant_buf = vim.api.nvim_get_current_buf()
local dormant_settled
pipeline.for_buffer(flow.get_config(), dormant_buf, function(_, _, dormant)
  dormant_settled = dormant
end)
harness.wait(function()
  return dormant_settled ~= nil
end, "the dormant resolve should settle")
assert_equal(dormant_settled, true, "no base can be guessed in a repository without a remote")
assert_equal(
  marks_by_line(dormant_buf, "agentic-flow-hunks"),
  {},
  "a dormant repository decorates nothing"
)
assert_equal(notifications, {}, "a dormant repository says nothing on the ambient path")

-- Buffer switches keep asking the pipeline which context owns the file. The
-- pipeline memoises the dormant answer, so the signs module needs no duplicate
-- per-buffer "probed" cache of its own.
local dormant_probes, resolvable_probes = 0, 0
local original_for_buffer = pipeline.for_buffer
rawset(pipeline, "for_buffer", function(probe_config, target, callback)
  if target == dormant_buf then
    dormant_probes = dormant_probes + 1
  elseif target == review_only_buf then
    resolvable_probes = resolvable_probes + 1
  end
  return original_for_buffer(probe_config, target, callback)
end)
for _ = 1, 3 do
  vim.cmd.buffer(review_only_buf)
  vim.cmd.buffer(dormant_buf)
end
rawset(pipeline, "for_buffer", original_for_buffer)
assert_equal(resolvable_probes > 0, true, "entering a buffer asks which context owns it")
assert_equal(dormant_probes > 0, true, "dormant ownership is delegated to the pipeline memo")

local original_select = vim.ui.select
local offered_bases
rawset(vim.ui, "select", function(items, _opts, on_choice)
  offered_bases = items
  for _, item in ipairs(items) do
    if item.name == "main" then
      return on_choice(item)
    end
  end
  on_choice(nil)
end)
flow.toggle_reviewed()
local dormant_key = pipeline.key(dormant_root, "main", "main")
harness.wait(function()
  local dormant_context = pipeline.get(dormant_key)
  return dormant_context and review.file_status(dormant_context, "dormant.txt") == "reviewed"
end, "a command run in a dormant repository continues after the user picks a base")
assert_equal(
  offered_bases[1].name,
  "main",
  "an explicit command in a dormant repository opens the existing base picker"
)
assert_equal(notifications, {}, "picking a base does not turn ambient dormancy into an error")
rawset(vim.ui, "select", original_select)
pipeline.close(dormant_key)
rawset(vim, "notify", original_notify)

-- A checkout moves a repository's context to a new key. Attachments name a key,
-- so unless they move too the gutter keeps decorating from the branch the user
-- just left. Asserted by evicting the OLD key: that strips only the buffers
-- still attached to it, so surviving marks prove the attachment migrated.
local migrate_root = harness.repo()
harness.write(migrate_root .. "/tracked.txt", { "base" })
harness.run(migrate_root, "git", "add", ".")
harness.run(migrate_root, "git", "commit", "-m", "base")
harness.run(migrate_root, "git", "checkout", "--quiet", "-b", "feature")
harness.write(migrate_root .. "/tracked.txt", { "changed" })

local migrate_context =
  assert(harness.await(pipeline.open, config, { root = migrate_root, base = "main" }))
local migrate_buf = vim.fn.bufadd(migrate_root .. "/tracked.txt")
vim.fn.bufload(migrate_buf)
signs.attach(config, migrate_context, "tracked.txt", migrate_buf, "after")
local migrate_ns = vim.api.nvim_get_namespaces()["agentic-flow-hunks"]
local function migrate_marks()
  return #vim.api.nvim_buf_get_extmarks(migrate_buf, migrate_ns, 0, -1, {})
end
assert_equal(migrate_marks() > 0, true, "the buffer decorates before the checkout")

local migrations = {}
vim.api.nvim_create_autocmd("User", {
  pattern = "AgenticFlowContextMigrated",
  callback = function(args)
    migrations[#migrations + 1] = args.data
  end,
})
harness.run(migrate_root, "git", "checkout", "--quiet", "main")
assert(harness.await(function(done)
  pipeline.refresh(done, migrate_context.key)
end))
harness.wait(function()
  return #migrations > 0
end, "the checkout migrates the context to a new key")
assert_equal(migrations[1].from, migrate_context.key, "the migration names the key it left")

pipeline.close(migrate_context.key)
assert_equal(
  migrate_marks() > 0,
  true,
  "evicting the outgoing key leaves the buffer decorated: its attachment moved with the context"
)

print("signs_spec passed")
