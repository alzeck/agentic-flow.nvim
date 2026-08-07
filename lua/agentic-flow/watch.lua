--- Ambient refresh triggers. Exactly one watcher exists and it
--- follows the *foreground repository* — the repository of the most recent
--- ordinary file buffer. The sidebar, comments list, comment editor floats,
--- terminals and help buffers never retarget it, so the handle cost is a flat
--- 1 timer + 4 `fs_event` however many contexts are cached; a cached but
--- backgrounded context costs nothing and is refreshed on demand when it
--- becomes foreground again.
---
--- Filesystem callbacks do no Neovim work: they only reset a libuv timer,
--- whose scheduled completion asks the async pipeline to refresh the context
--- the watcher currently names. A checkout moves that name, so the watcher
--- follows `AgenticFlowContextMigrated` like the rest of the UI.
local pipeline = require("agentic-flow.pipeline")
local util = require("agentic-flow.util")

local M = {}

local uv = vim.uv
---@class AgenticFlow.WatchState
---@field key string
---@field root string
---@field storage_dir string
---@field handles uv.uv_fs_event_t[]
---@field timer uv.uv_timer_t

---@type AgenticFlow.Config?
local config
---@type AgenticFlow.WatchState?
local active
local enabled = true
---@type string?
local foreground_key

---@param buf integer
---@return boolean
local function ordinary_file(buf)
  return vim.api.nvim_buf_is_valid(buf)
    and vim.bo[buf].buftype == ""
    and vim.api.nvim_buf_get_name(buf) ~= ""
end

---@param handle? uv.uv_timer_t|uv.uv_fs_event_t
local function close_handle(handle)
  if not handle then
    return
  end
  pcall(handle.stop, handle)
  if not handle:is_closing() then
    handle:close()
  end
end

---@param filename? string
---@return boolean
local function ignored_worktree_event(filename)
  if not active or not filename then
    return false
  end
  filename = filename:gsub("\\", "/")
  if filename == ".git" or vim.startswith(filename, ".git/") then
    return true
  end
  local path = util.absolute(active.root, filename)
  return util.relative(active.storage_dir, path) ~= nil
end

---Queue a debounced refresh for the watched context.
---@param key? string only trigger when this review still owns the watcher
function M.trigger(key)
  local watched = active
  if not watched or (key and key ~= watched.key) then
    return
  end
  ---@cast config -nil
  watched.timer:stop()
  watched.timer:start(config.debounce_ms, 0, function()
    vim.schedule(function()
      -- `watched.key` is read late on purpose: a checkout that migrated the
      -- watcher mid-debounce must refresh the key it moved to.
      if active ~= watched or pipeline.get(watched.key) == nil then
        return
      end
      pipeline.refresh(function(_, err)
        if err and active == watched then
          util.notify("Could not refresh review: " .. err, vim.log.levels.WARN)
        end
      end, watched.key)
    end)
  end)
end

---@param path string
---@param recursive boolean
---@param callback uv.fs_event_start.callback
local function add_watcher(path, recursive, callback)
  if not uv.fs_stat(path) then
    return
  end
  local handle = uv.new_fs_event()
  if not handle then
    return
  end
  local ok, started, err = pcall(handle.start, handle, path, { recursive = recursive }, callback)
  if not ok or not started then
    close_handle(handle)
    vim.schedule(function()
      util.notify(
        ("Could not watch %s: %s"):format(path, tostring(ok and err or started)),
        vim.log.levels.WARN
      )
    end)
    return
  end
  ---@cast active -nil
  active.handles[#active.handles + 1] = handle
end

---@param err? string
local function fs_callback(err)
  if err then
    return
  end
  M.trigger()
end

---Stop the watcher and discard its pending debounce.
---@param key? string only stop when this review owns the watcher
function M.stop(key)
  local watched = active
  if not watched or (key and key ~= watched.key) then
    return
  end
  active = nil
  close_handle(watched.timer)
  for _, handle in ipairs(watched.handles) do
    close_handle(handle)
  end
end

---Point the single watcher at `context`. A context in the repository already
---being watched only moves the name — the handles are watching the right
---paths already — so switching base or branch inside one repository costs no
---handle churn. A different repository tears the handles down and rebuilds
---them; nothing ever adds a sixth handle.
---@param context AgenticFlow.Context
---@return boolean retargeted true when the watcher changed the context it names
function M.start(context)
  if not enabled then
    return false
  end
  if active and active.key == context.key then
    return false
  end
  if active and active.root == context.root and active.storage_dir == context.storage_dir then
    active.key = context.key
    return true
  end
  M.stop()

  local timer = uv.new_timer()
  if not timer then
    util.notify("Could not create the review refresh timer", vim.log.levels.WARN)
    return false
  end
  active = {
    key = context.key,
    root = context.root,
    storage_dir = context.storage_dir,
    handles = {},
    timer = timer,
  }

  -- libuv's recursive fs_event support is available on macOS. Linux watches
  -- the root non-recursively and relies on BufWritePost/FocusGained for
  -- changes below nested directories.
  local recursive = uv.os_uname().sysname == "Darwin"
  add_watcher(context.root, recursive, function(err, filename)
    if not err and not ignored_worktree_event(filename) then
      M.trigger()
    end
  end)

  local git_dir = vim.fs.dirname(context.storage_dir)
  add_watcher(git_dir .. "/index", false, fs_callback)
  add_watcher(git_dir .. "/HEAD", false, fs_callback)
  add_watcher(git_dir .. "/refs", recursive, fs_callback)
  return true
end

---Retarget the watcher at the repository of an ordinary file buffer. Only a
---named `buftype == ""` buffer counts as foreground: the sidebar is a `nofile`
---buffer, the comment editor an `acwrite` float, and terminal, quickfix and
---help buffers carry their own buftypes — none of them may move the watcher
---off the repository the user is editing in. The name matters as much as the
---buftype, because a split is an ordinary unnamed buffer for the moment
---between `:new` and the `buftype` that makes it a panel.
---@param buf? integer
function M.follow(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not config or not ordinary_file(buf) then
    return
  end
  local context = pipeline.buffer_context(buf)
  if context then
    foreground_key = context.key
    if not enabled then
      return
    end
    if M.start(context) then
      -- Nothing watched this repository while it was backgrounded, so its
      -- context is only as fresh as the last time it was foreground.
      M.trigger(context.key)
    end
    return
  end
  if not enabled then
    return
  end
  pipeline.for_buffer(config, buf, function(resolved)
    -- The user may have moved on during the resolve; the watcher belongs to
    -- whatever is foreground now, and a fresh resolve needs no refresh.
    if resolved and vim.api.nvim_get_current_buf() == buf then
      foreground_key = resolved.key
      M.start(resolved)
    end
  end)
end

---Gate every automatic watcher path for the session-wide decoration toggle.
---Disabling also tears down the current handles; enabling permits the caller
---to reattach and refresh the foreground context explicitly.
---@param on boolean
function M.set_enabled(on)
  enabled = on and true or false
  if not enabled then
    M.stop()
  end
end

---@return string?
function M.active_key()
  return active and active.key or nil
end

---@return string?
function M.foreground_key()
  return foreground_key
end

---The watcher's libuv handle cost: its timer plus every `fs_event` it opened.
---Flat by design — caching more contexts must never add handles.
---@return integer
function M.handle_count()
  return active and #active.handles + 1 or 0
end

---Wire editor and pipeline events. Calling setup again replaces the event
---handlers and releases the watcher until the next foreground buffer.
---@param opts AgenticFlow.Config
function M.setup(opts)
  config = opts
  M.stop()
  local group = vim.api.nvim_create_augroup("AgenticFlowWatch", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(args)
      if not active then
        return
      end
      local path = vim.api.nvim_buf_get_name(args.buf)
      if
        path ~= ""
        and util.relative(active.root, path)
        and not util.relative(active.storage_dir, path)
      then
        M.trigger(active.key)
      end
    end,
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      M.trigger()
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(args)
      M.follow(args.buf)
    end,
  })
  -- A checkout re-keys the repository under the watcher. The root and the git
  -- directory are unchanged, so the handles stay put and only the name moves.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AgenticFlowContextMigrated",
    callback = function(args)
      if active and args.data and args.data.from == active.key then
        active.key = args.data.to
      end
      if foreground_key and args.data and args.data.from == foreground_key then
        foreground_key = args.data.to
      end
    end,
  })
  -- The foreground repository owns the watcher, so a resolve never steals it.
  -- An idle watcher is a different matter: a sidebar opened before any file
  -- buffer exists has no foreground to lose to, and must still watch.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AgenticFlowContextRefreshed",
    callback = function(args)
      if not enabled or active or not args.data or args.data.reason ~= "refresh" then
        return
      end
      local buf = vim.api.nvim_get_current_buf()
      if ordinary_file(buf) then
        M.follow(buf)
        return
      end
      local context = foreground_key and pipeline.get(foreground_key) or pipeline.get(args.data.key)
      if context then
        M.start(context)
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AgenticFlowReviewClosed",
    callback = function(args)
      local key = args.data and args.data.key or nil
      M.stop(key)
      if key and key == foreground_key then
        foreground_key = nil
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.stop()
    end,
  })
end

return M
