local harness = require("tests.harness")
local pipeline = require("agentic-flow.pipeline")
local review = require("agentic-flow.review")
local state = require("agentic-flow.state")

local assert_equal = harness.assert_equal
local assert_contains = harness.assert_contains

local config = require("agentic-flow").get_config()
local root = harness.fixture_repo()

local events = {}
vim.api.nvim_create_autocmd("User", {
  pattern = "AgenticFlowContextRefreshed",
  callback = function(args)
    events[args.data.reason] = (events[args.data.reason] or 0) + 1
  end,
})

local notifications = {}
local original_notify = vim.notify
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(message, level, _opts)
  notifications[#notifications + 1] = { message = message, level = level }
end

-- Open with a one-shot explicit base: resolved, cached, event emitted,
-- nothing remembered.
local context = assert(harness.await(pipeline.open, config, { root = root, base = "upstream" }))
assert_equal(context.branch, "feature", "the branch should be detected")
assert_equal(context.base, "upstream", "the explicit base should be used")
assert_equal(
  pipeline.get(context.key) == context,
  true,
  "get() returns the cached context synchronously"
)
assert_equal(pipeline.get(), nil, "get() without a key has no ambient answer")
assert_equal(events.refresh, 1, "opening emits one refresh event")
assert_equal(
  state.remembered_base(context.storage_dir, "feature"),
  nil,
  "a one-shot base override is not remembered"
)

-- Explicit selection remembers; later opens use the remembered base.
local remembered = assert(
  harness.await(pipeline.open, config, { root = root, base = "upstream", remember_base = true })
)
assert_equal(
  state.remembered_base(remembered.storage_dir, "feature"),
  "upstream",
  "explicit base selection is remembered"
)
context = assert(harness.await(pipeline.open, config, { root = root }))
assert_equal(
  context.base,
  "upstream",
  "the remembered base wins over the configured default (origin/main does not exist here)"
)
local key = context.key

-- Coalescing: a burst of refresh calls produces exactly one in-flight
-- resolve plus one dirty follow-up.
local refreshes_before = events.refresh
pipeline.refresh(nil, key)
pipeline.refresh(nil, key)
pipeline.refresh(nil, key)
harness.wait(function()
  return events.refresh >= refreshes_before + 2 and not pipeline.refreshing(key)
end, "the coalesced follow-up should settle")
vim.wait(300)
assert_equal(events.refresh, refreshes_before + 2, "a burst coalesces into one follow-up")

-- Mutations validate against the cache and emit an event.
local fingerprint = pipeline.get(key).by_file["hunks.txt"].hunks[1].fingerprint
local mutations_before = events.mutation or 0
local toggled = assert(pipeline.toggle_hunk(key, "hunks.txt", fingerprint))
assert_equal(toggled.reviewed, 1, "the toggle should apply")
assert_equal(events.mutation, mutations_before + 1, "mutations emit a context event")
assert_equal(
  review.file_status(assert(pipeline.get(key)), "hunks.txt"),
  "partial",
  "the cached context reflects the mutation"
)

-- Stale mutation: edit the reviewed hunk on disk, refresh, then toggle the
-- old fingerprint — warning no-op, state untouched.
local lines = vim.fn.readfile(root .. "/hunks.txt")
lines[2] = "changed hunk two differently"
harness.write(root .. "/hunks.txt", lines)
assert(harness.await(function(done)
  pipeline.refresh(done, key)
end))
local stale_result, stale_error = pipeline.toggle_hunk(key, "hunks.txt", fingerprint)
assert_equal(stale_result, nil, "a stale fingerprint must not toggle")
assert_contains(stale_error, "no longer part", "stale toggles explain themselves")
assert_contains(
  notifications[#notifications].message,
  "no longer part",
  "stale toggles warn the user"
)
assert_equal(
  { review.hunk_progress(assert(pipeline.get(key)), "hunks.txt") },
  { 0, 2 },
  "state stays untouched after a stale toggle"
)

-- Comment ops route through the same validation.
local comment = assert(pipeline.create_comment(key, { file = "tracked.txt", text = "Note." }))
assert_equal(comment.path, "tracked.txt", "comments apply through the pipeline")
local foreign = pipeline.create_comment(key, { file = "not-here.txt", text = "Note." })
assert_equal(foreign, nil, "comments on unknown files are warning no-ops")

-- A second base for the same repository resolves without disturbing the first.
local main_context = assert(harness.await(pipeline.open, config, { root = root, base = "main" }))
assert_equal(main_context.key ~= key, true, "a different base is a different context")

-- A second repository, seeded with a remembered base and then evicted, so the
-- buffer below has to resolve it from nothing.
local ambient_root = harness.fixture_repo()
local seeded = assert(
  harness.await(
    pipeline.open,
    config,
    { root = ambient_root, base = "upstream", remember_base = true }
  )
)
pipeline.close(seeded.key)
assert_equal(pipeline.get(seeded.key), nil, "eviction drops the seeded context")

-- A buffer opened with :e — never through the sidebar — resolves the context
-- that owns it, stamps itself, and answers from the cache from then on.
local ambient_buf = vim.fn.bufadd(ambient_root .. "/tracked.txt")
vim.fn.bufload(ambient_buf)
assert_equal(pipeline.buffer_context(ambient_buf), nil, "an unseen buffer names no context")
local ambient_context = assert(harness.await(function(done)
  pipeline.for_buffer(config, ambient_buf, done)
end))
assert_equal(ambient_context.key, seeded.key, "the buffer resolves its own repository and branch")
assert_equal(
  { vim.b[ambient_buf].agentic_flow_root, vim.b[ambient_buf].agentic_flow_base },
  { ambient_root, "upstream" },
  "resolving stamps the buffer with the context that owns it"
)
assert_equal(
  pipeline.buffer_context(ambient_buf),
  ambient_context,
  "a stamped buffer resolves synchronously"
)
local sibling_buf = vim.fn.bufadd(ambient_root .. "/hunks.txt")
vim.fn.bufload(sibling_buf)
assert_equal(
  pipeline.buffer_context(sibling_buf),
  ambient_context,
  "another buffer in the same repository answers from the memo, unresolved"
)

-- Every context resolved so far is still cached: nothing evicts anything else.
assert_equal({
  pipeline.get(key) ~= nil,
  pipeline.get(main_context.key) ~= nil,
  pipeline.get(ambient_context.key) ~= nil,
}, { true, true, true }, "contexts for different repositories and bases hold simultaneously")
assert_equal(
  pipeline.get(ambient_context.key).root ~= pipeline.get(key).root,
  true,
  "each cached context keeps its own repository"
)

-- Base guessing. A clone whose remote default branch is neither
-- `main` nor `master`, so only `origin/HEAD` can answer.
local function cloned_repo()
  local origin = harness.repo()
  harness.write(origin .. "/tracked.txt", { "alpha" })
  harness.run(origin, "git", "add", ".")
  harness.run(origin, "git", "commit", "-m", "base")
  harness.run(origin, "git", "branch", "-m", "trunk")
  local clone = vim.fn.tempname()
  harness.run(vim.fs.dirname(clone), "git", "clone", "--quiet", origin, clone)
  clone = vim.fs.normalize(assert(vim.uv.fs_realpath(clone)))
  harness.run(clone, "git", "config", "user.email", "tests@example.com")
  harness.run(clone, "git", "config", "user.name", "Agentic Flow Tests")
  harness.run(clone, "git", "config", "commit.gpgsign", "false")
  harness.run(clone, "git", "checkout", "--quiet", "-b", "feature")
  harness.write(clone .. "/tracked.txt", { "ALPHA" })
  return clone
end

local clone_root = cloned_repo()
local notifications_before = #notifications
local guessed = assert(harness.await(pipeline.open, config, { root = clone_root }))
assert_equal(
  { guessed.base, guessed.base_source },
  { "origin/HEAD", "guess" },
  "a branch with no remembered base resolves against origin/HEAD, no command run"
)
assert_equal(
  guessed.by_file["tracked.txt"] ~= nil,
  true,
  "the guessed context diffs against the remote default branch"
)
assert_equal(#notifications, notifications_before, "guessing a base says nothing")
assert_equal(
  vim.uv.fs_stat(guessed.storage_dir .. "/config.json"),
  nil,
  "a guessed session leaves config.json untouched"
)
assert_equal(
  state.remembered_base(guessed.storage_dir, "feature"),
  nil,
  "a guess is never remembered"
)
-- A refresh of a guessed context keeps both the base and the fact it was
-- guessed, so the sidebar title cannot quietly start claiming it was chosen.
local refreshed = assert(harness.await(function(done)
  pipeline.refresh(done, guessed.key)
end))
assert_equal(
  { refreshed.base, refreshed.base_source },
  { "origin/HEAD", "guess" },
  "refreshing a guessed context re-resolves the same guessed base"
)

-- An explicit pick outranks every guess, and keeps outranking it afterwards.
local picked = assert(
  harness.await(pipeline.open, config, { root = clone_root, base = "trunk", remember_base = true })
)
assert_equal(picked.base_source, "explicit", "a picked base is explicit")
local remembered_context = assert(harness.await(pipeline.open, config, { root = clone_root }))
assert_equal(
  { remembered_context.base, remembered_context.base_source },
  { "trunk", "remembered" },
  "a remembered base wins over origin/HEAD"
)

-- A configured base is a decision, not a guess, so it outranks the inferred
-- `origin/HEAD` — but still loses to a base the user picked for this branch.
-- A fresh clone, so no earlier pick is remembered here.
local configured_root = cloned_repo()
local configured = vim.tbl_deep_extend("force", vim.deepcopy(config), { base = "trunk" })
local from_config = assert(harness.await(pipeline.open, configured, { root = configured_root }))
assert_equal(
  { from_config.base, from_config.base_source },
  { "trunk", "configured" },
  "a configured base outranks origin/HEAD"
)
assert_equal(
  vim.uv.fs_stat(from_config.storage_dir .. "/config.json"),
  nil,
  "a configured base is not remembered either — only an explicit pick is"
)
assert(state.remember_base(from_config.storage_dir, "feature", "origin/HEAD"))
local pick_beats_config =
  assert(harness.await(pipeline.open, configured, { root = configured_root }))
assert_equal(
  { pick_beats_config.base, pick_beats_config.base_source },
  { "origin/HEAD", "remembered" },
  "a base picked for this branch still outranks the configured default"
)
pipeline.close(from_config.key)
pipeline.close(pick_beats_config.key)

-- A remembered base that no longer exists falls through to the guesses rather
-- than failing the resolve; an unverified ref is never used.
assert(state.remember_base(remembered_context.storage_dir, "feature", "deleted-branch"))
local fallen_back = assert(harness.await(pipeline.open, config, { root = clone_root }))
assert_equal(
  { fallen_back.base, fallen_back.base_source },
  { "origin/HEAD", "guess" },
  "a stale remembered base falls through to the guesses"
)
pipeline.close(guessed.key)
pipeline.close(remembered_context.key)

-- Buffers opened together in an unresolved repository share one resolve
-- instead of each paying for the whole guess.
harness.write(clone_root .. "/second.txt", { "second" })
local first_buf = vim.fn.bufadd(clone_root .. "/tracked.txt")
local second_buf = vim.fn.bufadd(clone_root .. "/second.txt")
vim.fn.bufload(first_buf)
vim.fn.bufload(second_buf)
local resolves_before = events.refresh
local shared = {}
pipeline.for_buffer(config, first_buf, function(resolved_context)
  shared[#shared + 1] = resolved_context
end)
pipeline.for_buffer(config, second_buf, function(resolved_context)
  shared[#shared + 1] = resolved_context
end)
harness.wait(function()
  return #shared == 2
end, "both buffers should resolve")
vim.wait(200)
assert_equal(shared[1] == shared[2], true, "concurrent first opens answer from one context")
assert_equal(events.refresh, resolves_before + 1, "and cost exactly one resolve")
assert_equal(
  vim.b[second_buf].agentic_flow_base,
  "origin/HEAD",
  "every buffer waiting on the resolve is stamped with the guessed base"
)
pipeline.close(shared[1].key)

-- No remote at all: dormant, silent, and decorating nothing.
local silent_root = harness.repo()
harness.write(silent_root .. "/tracked.txt", { "alpha" })
harness.run(silent_root, "git", "add", ".")
harness.run(silent_root, "git", "commit", "-m", "base")
harness.run(silent_root, "git", "checkout", "--quiet", "-b", "feature")
harness.write(silent_root .. "/tracked.txt", { "ALPHA" })
notifications_before = #notifications
local silent_context, silent_error, silent_dormant =
  harness.await(pipeline.open, config, { root = silent_root })
assert_equal(silent_context, nil, "a repository with no resolvable base stays dormant")
assert_equal(silent_dormant, true, "the dormant path is distinguishable from a real failure")
assert_contains(silent_error, "no comparison base", "the dormant reason explains itself")
assert_equal(#notifications, notifications_before, "a dormant repository never notifies")

local silent_buf = vim.fn.bufadd(silent_root .. "/tracked.txt")
vim.fn.bufload(silent_buf)
local _, buffer_error, buffer_dormant = harness.await(function(done)
  pipeline.for_buffer(config, silent_buf, done)
end)
assert_equal(buffer_dormant, true, "an ambient buffer lookup reports dormancy, not an error")
assert_contains(buffer_error, "no comparison base", "the buffer path carries the same reason")
assert_equal(pipeline.buffer_context(silent_buf), nil, "a dormant repository caches no context")
assert_equal(
  vim.api.nvim_buf_get_extmarks(silent_buf, -1, 0, -1, {}),
  {},
  "a dormant repository decorates nothing"
)
assert_equal(#notifications, notifications_before, "opening a buffer in it stays silent too")
local _, second_error, second_dormant = harness.await(function(done)
  pipeline.for_buffer(config, silent_buf, done)
end)
assert_contains(second_error, "no comparison base", "memoised dormancy keeps its reason")
assert_equal(second_dormant, true, "memoised dormancy retains its distinct result")
assert_equal(#notifications, notifications_before, "and stays silent however often it is asked")

-- Dormancy belongs to the branch, not the repository: a base is remembered per
-- branch, so checking out one that has a base must wake the repository up
-- rather than inherit the previous branch's silence.
harness.run(silent_root, "git", "checkout", "--quiet", "-b", "with-base")
harness.write(silent_root .. "/tracked.txt", { "ALPHA AGAIN" })
-- The base is remembered directly, exactly as an earlier session would have
-- left it. No open runs here, so nothing clears dormancy as a side effect and
-- the ambient path alone has to notice this branch is not the dormant one.
assert(state.remember_base(silent_root .. "/.git/agentic-flow", "with-base", "main"))
local woken_buf = vim.fn.bufadd(silent_root .. "/tracked.txt")
vim.fn.bufload(woken_buf)
local woken_context = assert(
  harness.await(function(done)
    pipeline.for_buffer(config, woken_buf, done)
  end),
  "a branch with a remembered base resolves even though another branch is dormant"
)
assert_equal(
  woken_context.branch,
  "with-base",
  "the woken context belongs to the checked-out branch"
)
pipeline.close(woken_context.key)
harness.run(silent_root, "git", "checkout", "--quiet", "feature")

-- Unknown keys and eviction.
assert_equal(pipeline.get("nope"), nil, "unknown keys have no cache")
assert_equal(pipeline.get(), nil, "a missing key resolves to no context at all")
pipeline.close(main_context.key)
pipeline.close(ambient_context.key)
pipeline.close(key)
assert_equal(pipeline.get(key), nil, "closing drops the cached context")
local _, closed_error = harness.await(pipeline.refresh)
assert_contains(closed_error, "not cached", "refreshing an uncached context reports it")

-- The context cache is a bounded LRU. A context named by a loaded buffer is
-- protected even when it is oldest; the least-recently-touched unprotected
-- context is evicted and announces the same close event as an explicit close.
local cap_root = harness.repo()
harness.write(cap_root .. "/tracked.txt", { "base" })
harness.run(cap_root, "git", "add", ".")
harness.run(cap_root, "git", "commit", "-m", "base")
for index = 1, 4 do
  harness.run(cap_root, "git", "branch", "base-" .. index)
end
harness.run(cap_root, "git", "checkout", "-b", "feature")
harness.write(cap_root .. "/tracked.txt", { "changed" })

local capped_config = vim.tbl_deep_extend("force", vim.deepcopy(config), { context_cap = 3 })
local capped = {}
for index = 1, 4 do
  capped[index] = assert(
    harness.await(pipeline.open, capped_config, { root = cap_root, base = "base-" .. index })
  )
  if index == 1 then
    local attached_buf = vim.fn.bufadd(cap_root .. "/tracked.txt")
    vim.fn.bufload(attached_buf)
    vim.b[attached_buf].agentic_flow_root = cap_root
    vim.b[attached_buf].agentic_flow_branch = "feature"
    vim.b[attached_buf].agentic_flow_base = "base-1"
  end
end
assert_equal(pipeline.get(capped[1].key) ~= nil, true, "a buffer-attached context is never evicted")
assert_equal(pipeline.get(capped[2].key), nil, "the oldest unprotected context is evicted")
assert_equal(
  { pipeline.get(capped[3].key) ~= nil, pipeline.get(capped[4].key) ~= nil },
  { true, true },
  "the three protected-or-newest contexts remain cached"
)
pipeline.close(capped[1].key)
pipeline.close(capped[3].key)
pipeline.close(capped[4].key)

vim.notify = original_notify
print("pipeline_spec passed")
