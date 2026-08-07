--- Async resolve pipeline. Contexts are cached per
--- `(root, branch, base)`; `get()` returns the cache immediately, `refresh()`
--- resolves in the background and swaps the cache on completion, emitting a
--- `User AgenticFlowContextRefreshed` autocmd. At most one resolve is in
--- flight per key — triggers during flight mark it dirty and coalesce into a
--- single follow-up. Mutations validate against the cached context: a stale
--- fingerprint is a warning no-op, never a corruption.
---
--- Review is ambient: there is no active context, every entry point
--- names the key it means, and a buffer resolves the context that owns it
--- through `for_buffer`.
---
--- A checkout moves a repository's context to a new key mid-resolve. The cache
--- takes the new key and the outgoing context stays cached, so bouncing back to
--- the previous branch is instant; `User AgenticFlowContextMigrated` tells
--- everything that still names the old key where it went.
---
--- A branch that has never had a base picked still resolves: the base is
--- guessed from the remote, and a guess is never written to `config.json` —
--- only an explicit pick is. A repository where no guess verifies stays
--- dormant and silent (`dormant` is the third callback argument) until a
--- command asks for it.

---@alias AgenticFlow.BaseSource "explicit"|"remembered"|"configured"|"guess"|"fallback"

---Everything one review needs, resolved as a unit and swapped atomically.
---@class AgenticFlow.Context
---@field key string cache key from `M.key(root, branch, base)`
---@field root string repository root, absolute
---@field storage_dir string `git rev-parse --git-path agentic-flow`, absolute
---@field branch string
---@field base string
---@field base_source AgenticFlow.BaseSource
---@field default_base? string the `setup()`-configured base, if any
---@field merge_base string commit the diff is taken against
---@field changes AgenticFlow.Change[] in tree order
---@field by_file table<string, AgenticFlow.Change>
---@field session AgenticFlow.Session

---@alias AgenticFlow.ResolveCallback fun(context: AgenticFlow.Context?, err: string?, dormant: boolean?)
---@alias AgenticFlow.BufferContextCallback fun(context: AgenticFlow.Context?, err: string?, dormant: boolean?, root: string?)

---@class AgenticFlow.ResolveOptions
---@field root? string
---@field base? string
---@field base_source? AgenticFlow.BaseSource
---@field branch? string
---@field default_base? string
---@field fallback_base? string
---@field remember_base? boolean

---@class AgenticFlow.OpenOptions
---@field root? string
---@field base? string
---@field remember_base? boolean
---@field migrate_from? string

local git = require("agentic-flow.git")
local review = require("agentic-flow.review")
local state = require("agentic-flow.state")
local util = require("agentic-flow.util")

local M = {}

---@type table<string, AgenticFlow.Context>
local caches = {}
local cache_cap = 8
local touch_clock = 0
---@type table<string, integer>
local touched = {}
---@type table<string|table, { dirty: boolean, callbacks: AgenticFlow.ResolveCallback[], superseded?: { key: string, reason: "checkout"|"base" }[] }>
local inflight = {}
---@type table<string, string>
local last_session_warning = {}
-- Directory → repository root, `false` once a directory is known not to be in
-- one. Every buffer under a directory reuses the first lookup.
---@type table<string, string|false>
local roots = {}
---@type table<string, fun(root: string?)[]>
local root_waiters = {}
-- Repository root → the buffers waiting on the first resolve for it, so a
-- burst of buffer opens costs one resolve rather than one each.
---@type table<string, { buf: integer, callback?: AgenticFlow.BufferContextCallback }[]>
local open_waiters = {}
-- Repository root → the key its last resolve produced, so the second buffer in
-- a repository reuses the cached parse instead of paying for the whole resolve
-- again.
---@type table<string, string>
local resolved = {}
-- `root\0branch` → the silent "no base could be guessed" result. Dormancy is a
-- successful ambient probe with nothing to display, not a transient error;
-- memoising it keeps every later buffer from repeating the full git chain.
-- Keyed by branch, not repository: a base is remembered per branch, so one
-- branch having nothing to compare against says nothing about the next.
---@type table<string, { err: string }>
local dormant = {}
local open_for_buffer

---@param root string
---@param branch string
---@return string
local function dormant_key(root, branch)
  return root .. "\0" .. branch
end

---@param root string
---@param branch string
---@param base string
---@return string
function M.key(root, branch, base)
  return table.concat({ root, branch, base }, "\0")
end

---The repository a key belongs to. The only reader of the key's encoding
---besides `M.key` itself — decode through here rather than splitting inline,
---so the format stays a private matter between the two.
---@param key string
---@return string
function M.key_root(key)
  return vim.split(key, "\0", { plain = true })[1]
end

---The cached context for `key`, or nil. Every caller names the context it
---means; there is no ambient default.
---@param key? string
---@return AgenticFlow.Context?
function M.get(key)
  local context = key and caches[key] or nil
  if context and key then
    touch_clock = touch_clock + 1
    touched[key] = touch_clock
  end
  return context
end

---True while a resolve is in flight for `key`.
---@param key? string
---@return boolean
function M.refreshing(key)
  return key ~= nil and inflight[key] ~= nil
end

---@param pattern string
---@param key string
---@param reason? "refresh"|"mutation"
local function emit(pattern, key, reason)
  vim.api.nvim_exec_autocmds("User", {
    pattern = pattern,
    data = { key = key, reason = reason },
  })
end

---Evict one context and announce it. An in-flight resolve for the key is
---discarded on completion.
---@param key string
local function evict(key)
  local context = caches[key]
  local root = context and context.root or M.key_root(key)
  if context and resolved[context.root] == key then
    resolved[context.root] = nil
  end
  caches[key] = nil
  touched[key] = nil
  inflight[key] = nil
  last_session_warning[key] = nil
  if context then
    dormant[dormant_key(context.root, context.branch)] = nil
  end
  -- A resolve dropped mid-flight never reaches its callbacks, so release the
  -- buffers queued behind it: the repository must stay able to resolve again.
  open_waiters[root] = nil
  emit("AgenticFlowReviewClosed", key)
end

---Keys named by loaded buffers cannot be evicted: those buffers may still be
---decorated from the context. Checkout migration re-stamps them before this
---runs, which deliberately releases the outgoing branch for normal LRU
---consideration.
---@param extra? string
---@return table<string, boolean>
local function protected_keys(extra)
  local protected = {}
  if extra then
    protected[extra] = true
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
      local root = vim.b[buf].agentic_flow_root
      local branch = vim.b[buf].agentic_flow_branch
      local base = vim.b[buf].agentic_flow_base
      if type(root) == "string" and type(branch) == "string" and type(base) == "string" then
        local key = M.key(root, branch, base)
        if caches[key] then
          protected[key] = true
        end
      end
    end
  end
  return protected
end

---Trim to the configured cap, oldest touch first. If more than `cache_cap`
---contexts are protected by attached buffers, they all survive: correctness
---wins over the memory backstop.
---@param newest string
local function enforce_cache_cap(newest)
  local count = vim.tbl_count(caches)
  local protected = protected_keys(newest)
  while count > cache_cap do
    local oldest_key, oldest_touch
    for key in pairs(caches) do
      local at = touched[key] or 0
      if not protected[key] and (oldest_touch == nil or at < oldest_touch) then
        oldest_key, oldest_touch = key, at
      end
    end
    if not oldest_key then
      return
    end
    evict(oldest_key)
    count = count - 1
  end
end

---Abandon a resolve. `asleep` marks the one failure that is not a problem to
---report: no base could be guessed, so the branch has nothing to show until
---the user picks one.
---@param claim_key string|table
---@param err? string
---@param asleep? boolean
local function fail(claim_key, err, asleep)
  local flight = inflight[claim_key]
  inflight[claim_key] = nil
  vim.schedule(function()
    for _, callback in ipairs(flight and flight.callbacks or {}) do
      callback(nil, err, asleep)
    end
  end)
end

local run_resolve

---Announce that a repository's context landed under a different key than the
---resolve was claimed under — a checkout is the usual cause. The cache-layer
---transfer already happened and the outgoing context is deliberately left
---cached; what this adds is telling everything that named the old key where it
---went. Buffers stamped with it are re-stamped in place, and the UI follows
---`AgenticFlowContextMigrated`.
---@param from string the key the resolve was claimed under
---@param context AgenticFlow.Context the context it landed as
---@param reason "checkout"|"base"
local function migrate(from, context, reason)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local root = vim.b[buf].agentic_flow_root
    local branch = vim.b[buf].agentic_flow_branch
    local base = vim.b[buf].agentic_flow_base
    if
      type(root) == "string"
      and type(branch) == "string"
      and type(base) == "string"
      and M.key(root, branch, base) == from
    then
      vim.b[buf].agentic_flow_branch = context.branch
      vim.b[buf].agentic_flow_base = context.base
    end
  end
  vim.api.nvim_exec_autocmds("User", {
    pattern = "AgenticFlowContextMigrated",
    data = { from = from, to = context.key, root = context.root, reason = reason },
  })
end

---Swap the cache and notify. A finish whose flight was dropped (the context
---evicted mid-resolve) is discarded.
---@param key string
---@param context AgenticFlow.Context
local function finish(key, context)
  local flight = inflight[key]
  if not flight then
    return
  end
  inflight[key] = nil
  caches[key] = context
  touch_clock = touch_clock + 1
  touched[key] = touch_clock
  resolved[context.root] = key
  dormant[dormant_key(context.root, context.branch)] = nil
  -- Followers move their key before the refresh event, so the redraw it asks
  -- for is already the redraw of the context that arrived.
  for _, migration in ipairs(flight.superseded or {}) do
    migrate(migration.key, context, migration.reason)
  end
  enforce_cache_cap(key)
  emit("AgenticFlowContextRefreshed", key, "refresh")
  for _, callback in ipairs(flight.callbacks) do
    callback(context)
  end
  if flight.dirty then
    inflight[key] = { dirty = false, callbacks = {} }
    run_resolve({
      root = context.root,
      base = context.base,
      base_source = context.base_source,
      branch = context.branch,
      default_base = context.default_base,
      -- Survives the branch-change reset below so a checkout has something to
      -- fall back on when the repository has no remote to guess from.
      fallback_base = context.base,
    }, key)
  end
end

---Load the session, reconcile it, relocate comments (async for deleted
---files), then finish. Runs on the main loop.
---@param opts AgenticFlow.ResolveOptions
---@param key string
---@param root string
---@param storage_dir string
---@param branch string
---@param resolution { base: string, source: AgenticFlow.BaseSource }
---@param merge_base string
---@param changes AgenticFlow.Change[]
local function assemble(opts, key, root, storage_dir, branch, resolution, merge_base, changes)
  local base = resolution.base
  local session, session_warning = state.load(storage_dir, branch, base)
  local context = {
    key = key,
    root = root,
    storage_dir = storage_dir,
    branch = branch,
    base = base,
    -- "explicit" | "remembered" | "guess": where the base came from, so the
    -- sidebar can show an inferred base as inferred rather than assumed.
    base_source = resolution.source,
    default_base = opts.default_base,
    merge_base = merge_base,
    changes = changes,
    by_file = {},
    session = session,
  }
  for _, change in ipairs(changes) do
    context.by_file[change.file] = change
  end
  review.sync_session(context)

  if session_warning and last_session_warning[key] ~= session_warning then
    last_session_warning[key] = session_warning
    util.notify(session_warning, vim.log.levels.WARN)
  end
  if opts.remember_base then
    local remembered, remember_error = state.remember_base(storage_dir, branch, base)
    if not remembered then
      util.notify(
        "Could not remember comparison base: " .. (remember_error or "unknown error"),
        vim.log.levels.WARN
      )
    end
  end

  local pending = {}
  for file, file_entry in pairs(session.files) do
    if #(file_entry.comments or {}) > 0 then
      local absolute = util.absolute(root, file)
      if vim.uv.fs_stat(absolute) then
        local contents = util.read_file(absolute)
        if contents and not contents:find("\0", 1, true) then
          review.relocate_comments(context, file, util.split_lines(contents))
        end
      elseif context.by_file[file] and context.by_file[file].status == "D" then
        pending[#pending + 1] = { file = file, old = context.by_file[file].old_file or file }
      end
    end
  end

  local remaining = #pending
  if remaining == 0 then
    return finish(key, context)
  end
  for _, item in ipairs(pending) do
    git.file_at(root, merge_base, item.old, function(contents)
      vim.schedule(function()
        if contents and not contents:find("\0", 1, true) then
          review.relocate_comments(context, item.file, util.split_lines(contents))
        end
        remaining = remaining - 1
        if remaining == 0 then
          finish(key, context)
        end
      end)
    end)
  end
end

---The bases to try for `branch`, best first. An explicit pick short-circuits
---everything; otherwise the base remembered in `config.json` leads, and the
---guesses follow it. `origin/HEAD` leads the guesses because it is the
---remote's own statement of its default branch; the configured `base` is the
---user's fallback ahead of the conventional names. Duplicates are dropped so
---no candidate is verified twice.
---@param opts AgenticFlow.ResolveOptions
---@param storage_dir string
---@param branch string
---@return { base: string, source: AgenticFlow.BaseSource }[]
local function base_candidates(opts, storage_dir, branch)
  if opts.base then
    return { { base = opts.base, source = opts.base_source or "explicit" } }
  end
  local candidates = {}
  local seen = {}
  ---@param base? string
  ---@param source string
  local function add(base, source)
    if base and not seen[base] then
      seen[base] = true
      candidates[#candidates + 1] = { base = base, source = source }
    end
  end
  add(state.remembered_base(storage_dir, branch), "remembered")
  -- A configured base is a decision and outranks the inferred `origin/HEAD`;
  -- the conventional names below it are only guesses.
  add(opts.default_base, "configured")
  add("origin/HEAD", "guess")
  add("origin/main", "guess")
  add("origin/master", "guess")
  -- Last resort on a checkout: carry the outgoing branch's comparison rather
  -- than going dark. A repository with no remote has no convention to guess
  -- from, so without this every checkout would blank a review that was working
  -- a moment ago. Like a guess it is never remembered, and the sidebar marks it
  -- as carried over so it is never mistaken for a base the user chose.
  add(opts.fallback_base, "fallback")
  return candidates
end

---One full async resolve. `claim_key` owns the inflight slot; once the real
---key is known the claim transfers (and merges into an existing flight for
---the same key instead of double-resolving).
---@param opts AgenticFlow.ResolveOptions
---@param claim_key string|table a real key for a refresh, a private token for an open
run_resolve = function(opts, claim_key)
  git.root(opts.root, function(root, root_error)
    if not root then
      return fail(claim_key, root_error or "not inside a Git repository")
    end
    git.storage_dir(root, function(storage_dir, storage_error)
      if not storage_dir then
        return fail(claim_key, storage_error)
      end
      git.branch(root, function(branch)
        vim.schedule(function()
          local branch_changed = opts.branch ~= nil and opts.branch ~= branch
          local resolve_opts = opts
          if branch_changed then
            resolve_opts = vim.tbl_extend("force", {}, opts)
            resolve_opts.base = nil
            resolve_opts.base_source = nil
            resolve_opts.remember_base = nil
          end
          local candidates = base_candidates(resolve_opts, storage_dir, branch)
          local refs = {}
          for index, candidate in ipairs(candidates) do
            refs[index] = candidate.base
          end
          -- The base is whichever candidate verifies first: an unverified ref
          -- is never used, so a stale remembered base falls through to the
          -- guesses instead of failing the whole resolve.
          git.first_valid_ref(root, refs, function(_, index)
            local resolution = index and candidates[index]
            if not resolution then
              if resolve_opts.base then
                return fail(
                  claim_key,
                  ("invalid comparison base %q: not found"):format(resolve_opts.base)
                )
              end
              -- Nothing to guess from: stay dormant rather than complain on
              -- every buffer opened on this branch.
              local err = ("no comparison base could be resolved for %q; pick one with :AgenticFlowBase"):format(
                branch
              )
              dormant[dormant_key(root, branch)] = { err = err }
              return fail(claim_key, err, true)
            end
            local base = resolution.base
            local key = M.key(root, branch, base)
            if key ~= claim_key then
              local flight = inflight[claim_key]
              inflight[claim_key] = nil
              if not flight then
                return
              end
              -- A resolve claimed under a real key that lands under another one
              -- is a migration, and the followers still naming the claim key
              -- have to be told once the new context is cached. An open claims
              -- under a private token instead, which names nothing.
              local superseded = flight.superseded or {}
              if type(claim_key) == "string" then
                superseded[#superseded + 1] = { key = claim_key, reason = "checkout" }
              end
              local merged = inflight[key]
              if merged then
                merged.dirty = true
                vim.list_extend(merged.callbacks, flight.callbacks)
                merged.superseded = vim.list_extend(merged.superseded or {}, superseded)
                return
              end
              flight.superseded = superseded
              inflight[key] = flight
              claim_key = key
            end
            if branch_changed and caches[key] then
              local cached = caches[key]
              return vim.schedule(function()
                finish(key, cached)
              end)
            end
            git.merge_base(root, base, function(merge_base, merge_error)
              if not merge_base then
                return fail(
                  claim_key,
                  ("could not find a merge-base with %q: %s"):format(
                    base,
                    merge_error or "unknown error"
                  )
                )
              end
              git.changes(root, merge_base, function(changes, changes_error)
                -- git.changes completes on the main loop.
                if not changes then
                  return fail(claim_key, changes_error)
                end
                assemble(
                  resolve_opts,
                  key,
                  root,
                  storage_dir,
                  branch,
                  resolution,
                  merge_base,
                  changes
                )
              end)
            end)
          end)
        end)
      end)
    end)
  end)
end

---Resolve a review context from scratch: full resolve, cache, event. Without
---an explicit `base` the base is remembered-or-guessed; a resolve that finds
---nothing to guess reports `dormant` and stays silent.
---@param config AgenticFlow.Config
---@param opts? AgenticFlow.OpenOptions
---@param callback? AgenticFlow.ResolveCallback
function M.open(config, opts, callback)
  opts = opts or {}
  cache_cap = config.context_cap or 8
  local token = {}
  inflight[token] = {
    dirty = false,
    callbacks = callback and { callback } or {},
    superseded = opts.migrate_from and { { key = opts.migrate_from, reason = "base" } } or {},
  }
  run_resolve({
    root = opts.root or vim.fn.getcwd(),
    base = opts.base,
    default_base = config.base,
    remember_base = opts.remember_base,
  }, token)
end

---Resolve (and memoise) the repository root a directory belongs to. Callers
---arriving while a lookup is in flight wait on the same subprocess.
---@param directory string
---@param callback fun(root: string?)
local function resolve_root(directory, callback)
  local memo = roots[directory]
  if memo ~= nil then
    return callback(memo or nil)
  end
  local waiting = root_waiters[directory]
  if waiting then
    waiting[#waiting + 1] = callback
    return
  end
  root_waiters[directory] = { callback }
  git.root(directory, function(root)
    vim.schedule(function()
      roots[directory] = root or false
      local waiters = root_waiters[directory] or {}
      root_waiters[directory] = nil
      for _, waiter in ipairs(waiters) do
        waiter(root)
      end
    end)
  end)
end

---The directory a buffer resolves its repository from. Only ordinary file
---buffers resolve on their own — every other buffer carries a stamped context
---or none at all.
---@param buf integer
---@return string?
local function buffer_directory(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return vim.fn.getcwd()
  end
  return vim.fs.dirname(vim.fs.normalize(name))
end

---Stamp the context that owns a buffer onto it; `buffer_context` reads these
---back on every later lookup.
---@param buf integer
---@param context AgenticFlow.Context
local function stamp(buf, context)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.b[buf].agentic_flow_root = context.root
  vim.b[buf].agentic_flow_branch = context.branch
  vim.b[buf].agentic_flow_base = context.base
end

---The cached context a buffer belongs to, resolving nothing. A buffer stamped
---with `(root, branch, base)` names its context outright; anything else falls
---back to the memo for its directory.
---@param buf? integer
---@return AgenticFlow.Context?
function M.buffer_context(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local root = vim.b[buf].agentic_flow_root
  local branch = vim.b[buf].agentic_flow_branch
  local base = vim.b[buf].agentic_flow_base
  if type(root) == "string" and type(branch) == "string" and type(base) == "string" then
    local context = M.get(M.key(root, branch, base))
    if context then
      return context
    end
  end
  local directory = buffer_directory(buf)
  local memo = directory and roots[directory] or nil
  return type(memo) == "string" and M.get(resolved[memo]) or nil
end

---The context that owns `buf`, resolved in the background when the buffer has
---not been seen before. A cached context comes back synchronously; an unseen
---buffer is stamped once its resolve lands, so the next lookup is free. A
---repository whose base cannot be guessed resolves to nothing with
---`dormant` set — the caller decides whether that is worth mentioning.
---@param config AgenticFlow.Config
---@param buf? integer
---@param callback? AgenticFlow.BufferContextCallback
---@return AgenticFlow.Context?
function M.for_buffer(config, buf, callback)
  buf = buf or vim.api.nvim_get_current_buf()
  local context = M.buffer_context(buf)
  if context then
    if callback then
      callback(context, nil, nil, context.root)
    end
    return context
  end
  local stamped = vim.api.nvim_buf_is_valid(buf) and vim.b[buf].agentic_flow_root or nil
  local directory = type(stamped) == "string" and stamped or buffer_directory(buf)
  if not directory then
    if callback then
      callback(nil, "the buffer does not belong to a repository")
    end
    return nil
  end
  resolve_root(directory, function(root)
    if not root then
      if callback then
        callback(nil, "not inside a Git repository")
      end
      return
    end
    local cached = M.get(resolved[root])
    if cached then
      stamp(buf, cached)
      if callback then
        callback(cached, nil, nil, root)
      end
      return
    end
    -- Dormancy is a property of the branch, not the repository: a base is
    -- remembered per branch, so one branch having nothing to compare against
    -- says nothing about the next. Resolving the branch here costs a single
    -- subprocess and is what stops a checkout onto a branch that *does* have a
    -- base from staying silent. The cached lookup above runs first so the warm
    -- path still costs nothing.
    git.branch(root, function(branch)
      -- `git.branch` answers from `on_exit`, so this lands in a fast event
      -- context. Callers reach for the sidebar's base picker from here, which
      -- is an API call and would fail; hop back to the main loop first.
      vim.schedule(function()
        local sleeping = branch and dormant[dormant_key(root, branch)]
        if sleeping then
          if callback then
            callback(nil, sleeping.err, true, root)
          end
          return
        end
        open_for_buffer(config, root, buf, callback)
      end)
    end)
  end)
  return nil
end

---The cold path once the repository is known to be awake: coalesce every
---buffer arriving during the first resolve onto it.
---@param config AgenticFlow.Config
---@param root string
---@param buf integer
---@param callback? AgenticFlow.BufferContextCallback
function open_for_buffer(config, root, buf, callback)
  -- Every buffer that arrives while the first resolve for a repository is
  -- running waits on it. Without this, opening a session's worth of buffers
  -- in a repository with no resolvable base would re-run the whole guess for
  -- each one.
  local waiting = open_waiters[root]
  if waiting then
    waiting[#waiting + 1] = { buf = buf, callback = callback }
    return
  end
  open_waiters[root] = { { buf = buf, callback = callback } }
  M.open(config, { root = root }, function(opened, err, asleep)
    local waiters = open_waiters[root] or {}
    open_waiters[root] = nil
    for _, waiter in ipairs(waiters) do
      if opened then
        stamp(waiter.buf, opened)
      end
      if waiter.callback then
        waiter.callback(opened, err, asleep, root)
      end
    end
  end)
end

---Background re-resolve of a cached context. Callback-first so async test
---helpers can await it.
---@param callback? fun(context: AgenticFlow.Context?, err: string?)
---@param key? string
function M.refresh(callback, key)
  local context = M.get(key)
  if not key or not context then
    if callback then
      callback(nil, "the review context is not cached")
    end
    return
  end
  if inflight[key] then
    inflight[key].dirty = true
    if callback then
      table.insert(inflight[key].callbacks, callback)
    end
    return
  end
  inflight[key] = { dirty = false, callbacks = callback and { callback } or {} }
  run_resolve({
    root = context.root,
    base = context.base,
    -- A refresh keeps the key it was given, so it keeps the base it was given
    -- — including where that base came from.
    base_source = context.base_source,
    branch = context.branch,
    default_base = context.default_base,
    fallback_base = context.base,
  }, key)
end

---Evict a context from the cache and announce it. An in-flight resolve for
---the key is discarded on completion.
---@param key? string
function M.close(key)
  if not key then
    return
  end
  evict(key)
end

---Run a domain mutation against the cached context; failures, including stale
---fingerprints, warn and change nothing.
---@generic T
---@param key? string
---@param action fun(context: AgenticFlow.Context): T?, string?
---@return T? result
---@return string? err
local function mutate(key, action)
  local context = M.get(key)
  if not context then
    util.notify("The review context is no longer available", vim.log.levels.WARN)
    return nil, "the review context is not cached"
  end
  local result, err = action(context)
  if not result then
    util.notify(err or "The review mutation failed", vim.log.levels.WARN)
    return nil, err
  end
  ---@cast key -nil
  emit("AgenticFlowContextRefreshed", key, "mutation")
  return result
end

---@param key? string
---@param file string
---@param fingerprint string
---@return { file: string, hunk: AgenticFlow.Hunk, status: "reviewed"|"pending", reviewed: integer, total: integer }? result
---@return string? err
function M.toggle_hunk(key, file, fingerprint)
  return mutate(key, function(context)
    return review.toggle_hunk(context, file, fingerprint)
  end)
end

---@param key? string
---@param file string
---@return { file: string, status: "reviewed"|"pending" }? result
---@return string? err
function M.toggle_file(key, file)
  return mutate(key, function(context)
    return review.toggle_file(context, file)
  end)
end

---Mark every file beneath a directory reviewed, or unmark them all. The whole
---fan-out is one mutation: one `state.save` and one redraw cover it however
---many files it reached.
---@param key? string
---@param directory string
---@return { directory: string, status: "reviewed"|"pending", files: string[] }? result
---@return string? err
function M.toggle_directory(key, directory)
  return mutate(key, function(context)
    return review.toggle_directory(context, directory)
  end)
end

---@param key? string
---@param opts { file: string, text: string, start_line?: integer, end_line?: integer, lines?: string[] }
---@return AgenticFlow.Comment? comment
---@return string? err
function M.create_comment(key, opts)
  return mutate(key, function(context)
    return review.create_comment(context, opts)
  end)
end

---@param key? string
---@param opts { id: string|number, text: string }
---@return AgenticFlow.Comment? comment
---@return string? err
function M.update_comment(key, opts)
  return mutate(key, function(context)
    return review.update_comment(context, opts)
  end)
end

---@param key? string
---@param id string|number
---@return true? ok
---@return string? err
function M.delete_comment(key, id)
  return mutate(key, function(context)
    local ok, err = review.delete_comment(context, id)
    return ok or nil, err
  end)
end

---@param key? string
---@return true? ok
---@return string? err
function M.clear_comments(key)
  return mutate(key, function(context)
    local ok, err = review.clear_comments(context)
    return ok or nil, err
  end)
end

return M
