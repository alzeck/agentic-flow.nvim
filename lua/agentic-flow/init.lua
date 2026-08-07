--- Public API for agentic-flow.nvim.
local git = require("agentic-flow.git")
local pipeline = require("agentic-flow.pipeline")
local review = require("agentic-flow.review")
local util = require("agentic-flow.util")

local M = {}

---@class AgenticFlow.SignsConfig
---@field add string
---@field change string
---@field delete string
---@field reviewed string
---@field comment string
---@field stale string

---@class AgenticFlow.DisplayConfig
---@field virtual_text boolean
---@field hunk_signs "always"|"review_only"

---The resolved configuration every module receives. `setup` deep-extends
---`AgenticFlow.UserConfig` over these defaults, so only `base` can stay unset.
---@class AgenticFlow.Config
---@field base? string review base; unset means infer from `origin/HEAD`
---@field clipboard string register the copy commands write to
---@field debounce_ms integer watcher debounce
---@field context_cap integer most contexts kept cached at once
---@field signs AgenticFlow.SignsConfig
---@field display AgenticFlow.DisplayConfig

---What users may pass to `setup`: any subset of the configuration.
---@class AgenticFlow.UserSignsConfig
---@field add? string
---@field change? string
---@field delete? string
---@field reviewed? string
---@field comment? string
---@field stale? string

---@class AgenticFlow.UserDisplayConfig
---@field virtual_text? boolean
---@field hunk_signs? "always"|"review_only"

---@class AgenticFlow.UserConfig
---@field base? string
---@field clipboard? string
---@field debounce_ms? integer
---@field context_cap? integer
---@field signs? AgenticFlow.UserSignsConfig
---@field display? AgenticFlow.UserDisplayConfig

---@class AgenticFlow.ContextOptions
---@field context? AgenticFlow.Context
---@field key? string
---@field buf? integer

---@class AgenticFlow.FileCommandOptions: AgenticFlow.ContextOptions
---@field file? string
---@field line? integer

---@class AgenticFlow.ChangesOptions
---@field root? string
---@field base? string
---@field remember_base? boolean
---@field migrate_from? string
---@field select_base? boolean
---@field buf? integer

---@class AgenticFlow.SelectBaseOptions
---@field root? string
---@field base? string
---@field buf? integer

---@class AgenticFlow.AddCommentOptions: AgenticFlow.FileCommandOptions
---@field start_line? integer
---@field end_line? integer
---@field file_level? boolean
---@field text? string

---@class AgenticFlow.CopyCommentsOptions: AgenticFlow.ContextOptions
---@field register? string

---@class AgenticFlow.RefreshOptions: AgenticFlow.ContextOptions
---@field callback? fun(context: AgenticFlow.Context?, err: string?)

---@type AgenticFlow.Config
local defaults = {
  -- Unset by default so a configured base stays distinguishable from an
  -- untouched one: setting it is a decision and outranks the inferred
  -- `origin/HEAD`, whereas a default would only be another guess.
  base = nil,
  clipboard = "+",
  debounce_ms = 400,
  context_cap = 8,
  signs = {
    add = "▎",
    change = "▎",
    delete = "_",
    reviewed = "▎",
    comment = "●",
    stale = "!",
  },
  display = {
    virtual_text = true,
    -- "always": decorate every buffer belonging to a resolved context.
    -- "review_only": decorate only buffers the plugin itself opened.
    hunk_signs = "always",
  },
}
local config = vim.deepcopy(defaults)
local initialized = false

---@param err? string
local function notify_error(err)
  util.notify(err or "Unknown review error", vim.log.levels.ERROR)
end

local function initialize()
  require("agentic-flow.signs").setup(config)
  require("agentic-flow.watch").setup(config)
  require("agentic-flow.diff").setup(config)
  initialized = true
end

local function ensure_initialized()
  if not initialized then
    initialize()
  end
end

---Run `fn` against the context the command applies to: an explicitly passed
---one, an explicit key, or the context that owns the buffer. A cached context
---answers immediately and `fn`'s return value is the command's; an unseen
---buffer resolves in the background and `fn` runs when it lands, so a command
---is never silently dropped for arriving before its context. A repository that
---cannot resolve stays silent ambiently but speaks up here — the user asked.
---
---`fn` runs later on the deferred path, so it must read cursor and buffer
---state itself rather than close over values read before the call.
---@param opts AgenticFlow.ContextOptions
---@param fn fun(context: AgenticFlow.Context): any
---@return any
local function with_context(opts, fn)
  if opts.context then
    return fn(opts.context)
  end
  if opts.key then
    local context = pipeline.get(opts.key)
    if not context then
      return notify_error("The review context is no longer available")
    end
    return fn(context)
  end
  opts.buf = opts.buf or vim.api.nvim_get_current_buf()
  local result
  pipeline.for_buffer(config, opts.buf, function(context, err, dormant, root)
    if not context then
      if dormant and root then
        return require("agentic-flow.tree").pick_base(root, function(base, pick_error)
          if not base then
            if pick_error then
              notify_error(pick_error)
            end
            return
          end
          pipeline.open(
            config,
            { root = root, base = base, remember_base = true },
            function(opened, open_error)
              if not opened then
                return notify_error(open_error)
              end
              result = fn(opened)
            end
          )
        end)
      end
      return util.notify(
        "Could not resolve a review here: " .. (err or "unknown error"),
        vim.log.levels.WARN
      )
    end
    result = fn(context)
  end)
  return result
end

---@param context AgenticFlow.Context
---@param opts AgenticFlow.FileCommandOptions
---@return string?
local function buffer_file(context, opts)
  if opts.file then
    return opts.file
  end
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  local stored = vim.b[buf].agentic_flow_path
  if type(stored) == "string" and stored ~= "" then
    return stored
  end
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= "" and util.relative(context.root, name) or nil
end

---@param buf integer
---@return integer
local function buffer_line(buf)
  if vim.api.nvim_get_current_buf() == buf then
    return vim.api.nvim_win_get_cursor(0)[1]
  end
  local windows = vim.fn.win_findbuf(buf)
  return #windows > 0 and vim.api.nvim_win_get_cursor(windows[1])[1] or 1
end

---@param buf integer
---@param context AgenticFlow.Context
---@param file string
local function set_buffer_context(buf, context, file)
  vim.b[buf].agentic_flow_root = context.root
  vim.b[buf].agentic_flow_branch = context.branch
  vim.b[buf].agentic_flow_base = context.base
  vim.b[buf].agentic_flow_path = file
end

---@param context AgenticFlow.Context
---@param file string
---@param buf integer
---@param line integer
local function finish_open(context, file, buf, line)
  vim.api.nvim_win_set_buf(0, buf)
  set_buffer_context(buf, context, file)
  require("agentic-flow.signs").attach(config, context, file, buf)
  line = math.max(1, math.min(line, math.max(1, vim.api.nvim_buf_line_count(buf))))
  vim.api.nvim_win_set_cursor(0, { line, 0 })
end

---@param context AgenticFlow.Context
---@param target { file_index: integer, file: string, change: AgenticFlow.Change, hunk: AgenticFlow.Hunk, line: integer }
---@return { file_index: integer, file: string, change: AgenticFlow.Change, hunk: AgenticFlow.Hunk, line: integer }?
local function open_target(context, target)
  local diff = require("agentic-flow.diff")
  if diff.is_open() then
    diff.retarget(config, context, target.file, target.line)
    return target
  end
  local change = context.by_file[target.file]
  if not change then
    return nil
  end
  if change.status == "D" then
    git.file_at(
      context.root,
      context.merge_base,
      change.old_file or change.file,
      function(contents, err)
        vim.schedule(function()
          if not contents then
            return notify_error(err)
          end
          local buf = vim.api.nvim_create_buf(false, true)
          vim.bo[buf].buftype = "nofile"
          vim.bo[buf].bufhidden = "wipe"
          vim.bo[buf].swapfile = false
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, util.split_lines(contents))
          vim.bo[buf].modifiable = false
          vim.bo[buf].readonly = true
          finish_open(context, target.file, buf, target.line)
        end)
      end
    )
    return target
  end
  local buf = vim.fn.bufadd(util.absolute(context.root, target.file))
  vim.fn.bufload(buf)
  finish_open(context, target.file, buf, target.line)
  return target
end

---Configure agentic-flow.nvim. Requires Neovim 0.11+.
---@param opts? AgenticFlow.UserConfig
function M.setup(opts)
  if vim.fn.has("nvim-0.11") ~= 1 then
    error("agentic-flow.nvim requires Neovim 0.11 or newer")
  end
  opts = opts or {}
  vim.validate("opts", opts, "table")
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  vim.validate("base", config.base, "string", true)
  vim.validate("clipboard", config.clipboard, "string")
  vim.validate("debounce_ms", config.debounce_ms, "number")
  vim.validate("context_cap", config.context_cap, function(value)
    return type(value) == "number" and value >= 1 and value % 1 == 0
  end, "a positive integer")
  vim.validate("signs", config.signs, "table")
  vim.validate("display", config.display, "table")
  vim.validate("display.virtual_text", config.display.virtual_text, "boolean")
  vim.validate("display.hunk_signs", config.display.hunk_signs, function(value)
    return value == "always" or value == "review_only"
  end, 'one of "always" or "review_only"')
  for _, name in ipairs({ "add", "change", "delete", "reviewed", "comment", "stale" }) do
    vim.validate("signs." .. name, config.signs[name], "string")
  end
  initialize()
end

---Return a copy of the active configuration.
---@return AgenticFlow.Config
function M.get_config()
  return vim.deepcopy(config)
end

---Open the changed-file review tree.
---@param opts? AgenticFlow.ChangesOptions
---@return integer?
function M.changes(opts)
  ensure_initialized()
  opts = vim.tbl_extend("force", {}, opts or {})
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  local context = pipeline.buffer_context(buf)
  if not context then
    local foreground_key = require("agentic-flow.watch").foreground_key()
    context = foreground_key and pipeline.get(foreground_key) or nil
  end
  if not opts.root then
    if context then
      opts.root = context.root
    elseif
      vim.api.nvim_buf_is_valid(buf)
      and vim.bo[buf].buftype == ""
      and vim.api.nvim_buf_get_name(buf) ~= ""
    then
      opts.root = vim.fs.dirname(vim.fs.normalize(vim.api.nvim_buf_get_name(buf)))
    end
  end
  if opts.base then
    opts.remember_base = true
    local requested_root = opts.root and vim.fs.normalize(opts.root) or nil
    if
      context
      and (
        not requested_root
        or requested_root == context.root
        or util.relative(context.root, requested_root) ~= nil
      )
    then
      opts.migrate_from = context.key
    end
  end
  return require("agentic-flow.tree").open(config, opts)
end

---Select and remember a comparison base without checking it out.
---@param opts? AgenticFlow.SelectBaseOptions
---@return integer|AgenticFlow.Context?
function M.select_base(opts)
  ensure_initialized()
  local tree = require("agentic-flow.tree")
  if tree.is_open() then
    return tree.select_base()
  end
  opts = opts or {}
  if opts.root then
    return tree.open(config, { root = opts.root, base = opts.base, select_base = true })
  end
  return pipeline.for_buffer(config, opts.buf, function(context, err, _dormant, root)
    if not root then
      return notify_error(err)
    end
    tree.open(config, {
      root = root,
      base = opts.base or (context and context.base) or nil,
      select_base = true,
    })
  end)
end

---Toggle whole-file reviewed state.
---@param opts? AgenticFlow.FileCommandOptions
---@return { file: string, status: "reviewed"|"pending" }? result
---@return string? err
function M.toggle_reviewed(opts)
  ensure_initialized()
  opts = opts or {}
  return with_context(opts, function(context)
    local file = buffer_file(context, opts)
    if not file then
      return notify_error("Could not determine the review file")
    end
    return pipeline.toggle_file(context.key, file)
  end)
end

---Toggle the hunk under the cursor on normal, deleted, or before-side buffers.
---@param opts? AgenticFlow.FileCommandOptions
---@return { file: string, hunk: AgenticFlow.Hunk, status: "reviewed"|"pending", reviewed: integer, total: integer }? result
---@return string? err
function M.toggle_hunk_reviewed(opts)
  ensure_initialized()
  opts = opts or {}
  return with_context(opts, function(context)
    local buf = opts.buf or vim.api.nvim_get_current_buf()
    local file = buffer_file(context, opts)
    if not file then
      return notify_error("Could not determine the review file")
    end
    if vim.bo[buf].modified then
      return util.notify("Save the buffer before reviewing its hunks", vim.log.levels.WARN)
    end
    local line = opts.line or buffer_line(buf)
    local hunk
    if vim.b[buf].agentic_flow_side == "before" then
      hunk = review.hunk_at_old_line(context, file, line)
    else
      hunk = review.hunk_at_line(context, file, line)
    end
    if not hunk then
      return util.notify("The cursor is not on a review hunk", vim.log.levels.WARN)
    end
    return pipeline.toggle_hunk(context.key, file, hunk.fingerprint)
  end)
end

---@param direction "next"|"previous"
---@param opts? AgenticFlow.FileCommandOptions
---@return { file_index: integer, file: string, change: AgenticFlow.Change, hunk: AgenticFlow.Hunk, line: integer }?
local function navigate(direction, opts)
  ensure_initialized()
  local diff = require("agentic-flow.diff")
  if diff.is_open() then
    return diff.navigate(direction)
  end
  opts = opts or {}
  return with_context(opts, function(context)
    local buf = opts.buf or vim.api.nvim_get_current_buf()
    local file = buffer_file(context, opts)
    local line = opts.line or buffer_line(buf)
    local target, err = review.navigation_target(context, file, line, direction)
    if not target then
      ---@cast err string
      util.notify(err, vim.log.levels.WARN)
      return nil
    end
    return open_target(context, target)
  end)
end

---@param opts? AgenticFlow.FileCommandOptions
---@return { file_index: integer, file: string, change: AgenticFlow.Change, hunk: AgenticFlow.Hunk, line: integer }?
function M.next_unreviewed(opts)
  return navigate("next", opts)
end

---@param opts? AgenticFlow.FileCommandOptions
---@return { file_index: integer, file: string, change: AgenticFlow.Change, hunk: AgenticFlow.Hunk, line: integer }?
function M.prev_unreviewed(opts)
  return navigate("previous", opts)
end

---Add a current-line, selected-range, or file-level comment.
---@param opts? AgenticFlow.AddCommentOptions
---@return AgenticFlow.Comment|integer?
function M.add_comment(opts)
  ensure_initialized()
  opts = opts or {}
  return with_context(opts, function(context)
    local buf = opts.buf or vim.api.nvim_get_current_buf()
    local file = buffer_file(context, opts)
    if not file then
      return notify_error("Could not determine the review file")
    end

    local start_line = opts.start_line
    local end_line = opts.end_line
    if opts.file_level then
      start_line, end_line = nil, nil
    elseif not start_line and not end_line and not opts.file then
      start_line = buffer_line(buf)
      end_line = start_line
    end

    local anchor_buf = buf
    if vim.b[buf].agentic_flow_side == "before" then
      local diff = require("agentic-flow.diff")
      local start_position = diff.position(buf, start_line or buffer_line(buf))
      local end_position = diff.position(buf, end_line or start_line or buffer_line(buf))
      if start_position and end_position then
        start_line = start_position.start_line or start_position.line
        end_line = end_position.end_line or end_position.line
      end
      anchor_buf = diff.after_buf() or buf
    end

    local create_opts = {
      file = file,
      start_line = start_line,
      end_line = end_line,
      lines = start_line and vim.api.nvim_buf_get_lines(anchor_buf, 0, -1, false) or nil,
    }
    if opts.text then
      create_opts.text = opts.text
      local comment, err = pipeline.create_comment(context.key, create_opts)
      if not comment then
        notify_error(err)
      end
      return comment
    end
    return require("agentic-flow.comments_ui").create(config, context, create_opts)
  end)
end

---Open the review comments list.
---@param opts? AgenticFlow.ContextOptions
---@return integer?
function M.comments(opts)
  ensure_initialized()
  return with_context(opts or {}, function(context)
    return require("agentic-flow.comments_ui").open(config, context)
  end)
end

---Copy every review comment to the configured or requested register.
---@param opts? AgenticFlow.CopyCommentsOptions
---@return string?
function M.copy_comments(opts)
  ensure_initialized()
  opts = opts or {}
  return with_context(opts, function(context)
    local output, err, count = review.copy_comments(context, opts.register or config.clipboard)
    if not output then
      ---@cast err string
      util.notify(err, vim.log.levels.WARN)
      return nil
    end
    util.notify(("%d review %s copied"):format(count, count == 1 and "comment" or "comments"))
    return output
  end)
end

---Refresh the review context this buffer belongs to.
---@param opts? AgenticFlow.RefreshOptions
function M.refresh(opts)
  ensure_initialized()
  opts = opts or {}
  local tree = require("agentic-flow.tree")
  if tree.is_open() then
    return tree.refresh(opts.callback)
  end
  return with_context(opts, function(context)
    return pipeline.refresh(opts.callback, context.key)
  end)
end

---Switch hunk signs and comment markers off, or back on, for this session. Off
---strips every mark and stops the watcher; on re-attaches, restarts the
---watcher and refreshes. Stored review state is untouched either way, so the
---round trip loses nothing.
---@param enable? boolean toggles when omitted
---@return boolean state after the call
function M.toggle_signs(enable)
  ensure_initialized()
  local signs = require("agentic-flow.signs")
  local watch = require("agentic-flow.watch")
  if enable == nil then
    enable = not signs.enabled()
  end
  signs.set_enabled(enable)
  if not enable then
    watch.set_enabled(false)
    util.notify("Review decoration off")
    return false
  end
  watch.set_enabled(true)
  -- Nothing was watched while decoration was off, so the context the user is
  -- editing in takes the watcher back and re-resolves rather than showing what
  -- it last knew. Panels do not own contexts, so the watcher's remembered
  -- foreground key restores the ordinary file that preceded one.
  local foreground_key = watch.foreground_key()
  local foreground = foreground_key and pipeline.get(foreground_key) or nil
  if foreground then
    watch.start(foreground)
    pipeline.refresh(nil, foreground.key)
    util.notify("Review decoration on")
    return true
  end
  pipeline.for_buffer(config, nil, function(context)
    if not context then
      return
    end
    watch.start(context)
    pipeline.refresh(nil, context.key)
  end)
  util.notify("Review decoration on")
  return true
end

---Toggle sticky built-in diff mode for the current review file.
---@param opts? AgenticFlow.FileCommandOptions
---@return boolean?
function M.toggle_diff(opts)
  ensure_initialized()
  local diff = require("agentic-flow.diff")
  if diff.is_open() then
    diff.close()
    return false
  end
  opts = opts or {}
  return with_context(opts, function(context)
    local buf = opts.buf or vim.api.nvim_get_current_buf()
    local file = buffer_file(context, opts)
    if not file then
      return notify_error("Could not determine the review file")
    end
    diff.open(config, context, file, opts.line or buffer_line(buf))
    return true
  end)
end

return M
