local harness = require("tests.harness")
local comments_ui = require("agentic-flow.comments_ui")
local pipeline = require("agentic-flow.pipeline")
local state = require("agentic-flow.state")
local watch = require("agentic-flow.watch")

local assert_equal = harness.assert_equal
local assert_contains = harness.assert_contains
local config = require("agentic-flow").get_config()
config.debounce_ms = 40

---Every live `fs_event` in the process, so "one watcher" can be asserted
---against libuv itself rather than against the plugin's own bookkeeping.
local function fs_events()
  local count = 0
  vim.uv.walk(function(handle)
    if vim.uv.handle_get_type(handle) == "fs_event" and not handle:is_closing() then
      count = count + 1
    end
  end)
  return count
end

---A repository on `feature`, comparable against `main`, with one changed file.
local function fixture()
  local root = harness.repo()
  harness.write(root .. "/tracked.txt", { "base" })
  harness.write(root .. "/nested/tracked.txt", { "nested base" })
  harness.run(root, "git", "add", ".")
  harness.run(root, "git", "commit", "-m", "base")
  harness.run(root, "git", "checkout", "--quiet", "-b", "feature")
  harness.write(root .. "/tracked.txt", { "changed" })
  return root
end

local function edit(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
end

local first = fixture()
local second = fixture()

watch.setup(config)
local a = assert(harness.await(pipeline.open, config, { root = first, base = "main" }))
local b = assert(harness.await(pipeline.open, config, { root = second, base = "main" }))
assert(state.remember_base(a.storage_dir, "feature", "main"))
assert(state.remember_base(a.storage_dir, "main", "feature"))
harness.wait(function()
  return watch.active_key() ~= nil
end, "a resolve with nothing in the foreground claims the idle watcher")

-- One watcher, retargeted rather than multiplied: it follows whichever
-- ordinary file buffer the user is in, across repositories.
edit(second .. "/tracked.txt")
harness.wait(function()
  return watch.active_key() == b.key
end, "entering a file retargets the watcher at its repository")
assert_equal(watch.handle_count(), 5, "the watcher costs one timer plus four fs_events")

edit(first .. "/tracked.txt")
harness.wait(function()
  return watch.active_key() == a.key
end, "editing back in the first repository follows the file again")
assert_equal(watch.handle_count(), 5, "retargeting replaces handles, it does not add them")

-- Handle cost is flat in the number of cached contexts.
local watched_events = fs_events()
local extra = {}
for _ = 1, 3 do
  local root = fixture()
  extra[#extra + 1] = assert(harness.await(pipeline.open, config, { root = root, base = "main" }))
end
extra[#extra + 1] = assert(harness.await(pipeline.open, config, { root = first, base = "feature" }))
assert_equal(
  { pipeline.get(a.key) ~= nil, pipeline.get(b.key) ~= nil, #extra },
  { true, true, 4 },
  "six contexts are cached at once"
)
assert_equal(watch.active_key(), a.key, "a background resolve never steals the foreground watcher")
assert_equal(watch.handle_count(), 5, "cached contexts cost no handles")
assert_equal(fs_events(), watched_events, "and libuv sees no extra fs_event either")

-- Buffers that are not ordinary files never retarget the watcher: the sidebar
-- is `nofile`, the comment editor `acwrite`.
for _, buftype in ipairs({ "nofile", "acwrite" }) do
  local decoy = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(decoy, ("%s/decoy-%s.txt"):format(second, buftype))
  vim.bo[decoy].buftype = buftype
  vim.api.nvim_set_current_buf(decoy)
  vim.wait(config.debounce_ms * 3)
  assert_equal(
    watch.active_key(),
    a.key,
    ("a %s buffer in another repository does not retarget the watcher"):format(buftype)
  )
  vim.bo[decoy].buftype = "nofile"
  vim.api.nvim_buf_delete(decoy, { force = true })
end
edit(first .. "/tracked.txt")
assert_equal(watch.active_key(), a.key, "the foreground repository is unchanged")

-- Losing the handles does not lose foreground ownership: a background refresh
-- cannot claim the idle watcher while an ordinary file from another repository
-- remains current.
watch.stop()
assert(harness.await(function(done)
  pipeline.refresh(done, b.key)
end))
harness.wait(function()
  return watch.active_key() == a.key
end, "an idle watcher should return to the current ordinary file, not the refreshed background")

-- Checkout. The comments list is a follower: comments live in a
-- `(branch, base)` session, so migrating the key swaps what it shows.
assert(pipeline.create_comment(a.key, { file = "tracked.txt", text = "Note." }))
comments_ui.open(config, assert(pipeline.get(a.key)))
local list_buf = assert(comments_ui.buf())
local function list_title()
  return vim.api.nvim_buf_get_lines(list_buf, 0, 1, false)[1]
end
assert_contains(list_title(), "1 review comment", "the list shows the feature branch's comment")

local migrations = {}
vim.api.nvim_create_autocmd("User", {
  pattern = "AgenticFlowContextMigrated",
  callback = function(args)
    migrations[#migrations + 1] = vim.deepcopy(args.data)
  end,
})

---How many distinct moves were announced, rather than how many announcements
---were made. One checkout can raise two resolves against the outgoing key —
---the explicit trigger and the checkout's own fs_event — and both land on the
---new key, so both say where it went. The repeat tells nobody anything new,
---and whether it happens at all is a timing artifact; the move itself is what
---happens exactly once.
local function distinct_migrations()
  local seen, count = {}, 0
  for _, migration in ipairs(migrations) do
    local move = migration.from .. " → " .. migration.to
    if not seen[move] then
      seen[move] = true
      count = count + 1
    end
  end
  return count
end

harness.run(first, "git", "checkout", "--quiet", "main")
local checked_out = pipeline.key(first, "main", "feature")
watch.trigger(a.key)
harness.wait(function()
  return watch.active_key() == checked_out
end, "a checkout migrates the watcher onto the new key")
assert_equal(
  { migrations[1].from, migrations[1].to, migrations[1].root },
  { a.key, checked_out, first },
  "the migration names the key it left, the key it landed on, and the repository"
)
local outgoing = assert(pipeline.get(a.key), "migrating must not evict the context it left")
assert_equal(
  { outgoing.branch, outgoing.by_file["tracked.txt"] ~= nil },
  { "feature", true },
  "the outgoing context stays cached, still parsed against the branch it belongs to"
)
assert_contains(list_title(), "0 review comments", "the comments list follows the key it moved to")
assert_equal(
  vim.b[vim.fn.bufadd(first .. "/tracked.txt")].agentic_flow_branch,
  "main",
  "buffers stamped with the old key are re-stamped, so they no longer name the old branch"
)
assert_equal(watch.handle_count(), 5, "a checkout keeps the repository, so the handles stay put")

-- Bouncing back is free: the previous context was never evicted, so it is
-- ready to render before anything is resolved. The `watch.trigger(a.key)`
-- above set a refresh going on that very key, so wait for it to land first —
-- otherwise what gets measured below is the tail of that refresh rather than
-- the cost of the bounce-back itself.
harness.wait(function()
  return not pipeline.refreshing(a.key)
end, "the refresh triggered on the outgoing key should land before the bounce-back")
harness.run(first, "git", "checkout", "--quiet", "feature")
assert_equal(
  { pipeline.get(a.key) ~= nil, pipeline.refreshing(a.key) },
  { true, false },
  "checking back out finds the previous context already parsed, with no re-resolve"
)
watch.trigger(checked_out)
harness.wait(function()
  return watch.active_key() == a.key
end, "and the watcher migrates back onto it")
assert_equal(distinct_migrations(), 2, "each checkout migrates exactly once")
assert_contains(list_title(), "1 review comment", "the comments list comes back with it")
assert_equal(
  pipeline.get(a.key),
  outgoing,
  "bouncing back restores the cached context object without rebuilding it"
)
comments_ui.close()
edit(first .. "/tracked.txt")

-- Let filesystem noise from the checkouts settle before observing triggers.
vim.wait(config.debounce_ms * 3)
local context = assert(pipeline.get(a.key))
local original_refresh = pipeline.refresh
local refreshes = {}
rawset(pipeline, "refresh", function(callback, key)
  refreshes[#refreshes + 1] = key
  if callback then
    callback(context)
  end
end)

-- Buffer writes under the root and FocusGained both request a refresh.
local buf = vim.fn.bufadd(first .. "/tracked.txt")
vim.fn.bufload(buf)
vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })
harness.wait(function()
  return #refreshes == 1
end, "BufWritePost should refresh the watched review")
assert_equal(refreshes[1], context.key, "buffer refreshes target the watched review")

vim.api.nvim_exec_autocmds("FocusGained", {})
harness.wait(function()
  return #refreshes == 2
end, "FocusGained should refresh the watched review")

-- A trigger storm collapses into one debounced refresh.
local before_storm = #refreshes
for _ = 1, 20 do
  watch.trigger(context.key)
end
harness.wait(function()
  return #refreshes > before_storm
end, "the debounced storm should eventually refresh")
vim.wait(config.debounce_ms * 3)
assert_equal(#refreshes - before_storm <= 2, true, "a trigger storm produces at most two resolves")

-- On macOS the recursive root watcher observes external nested writes without
-- relying on a buffer event or focus change.
if vim.uv.os_uname().sysname == "Darwin" then
  local before_external = #refreshes
  harness.write(first .. "/nested/tracked.txt", { "changed outside a buffer" })
  harness.wait(function()
    return #refreshes > before_external
  end, "external nested writes should refresh on macOS")
end

-- Closing the watched context tears down handles and pending timers.
rawset(pipeline, "refresh", original_refresh)
pipeline.close(context.key)
assert_equal(watch.active_key(), nil, "closing the watched review stops the watcher")
assert_equal(watch.handle_count(), 0, "and releases every handle it held")

print("watch_spec passed")
