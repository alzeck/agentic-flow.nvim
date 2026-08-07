--- Ambient, gitsigns-style sign engine. Any ordinary file buffer
--- belonging to a resolved context decorates, whether the plugin opened it or
--- `:e` did; marks are cleared when the context is evicted. Change kinds come
--- from the hunk line classification (git.parse_hunks): paired replacements
--- are changes, surplus additions are adds, unpaired deletions mark their
--- new-side anchor. Reviewed hunks collapse every kind into one dim sign.
---
--- Always-on decoration is reversible: `display.hunk_signs = "review_only"`
--- keeps decoration to buffers the plugin opened, and `M.set_enabled(false)`
--- (the `:AgenticFlowToggleSigns` kill switch) strips every mark mid-session
--- without touching stored review state.
local pipeline = require("agentic-flow.pipeline")
local review = require("agentic-flow.review")
local util = require("agentic-flow.util")

local M = {}

local hunk_ns = vim.api.nvim_create_namespace("agentic-flow-hunks")
local comment_ns = vim.api.nvim_create_namespace("agentic-flow-comments")

-- Above gitsigns' default sign priority (6) so both can coexist.
local HUNK_PRIORITY = 10
local COMMENT_PRIORITY = 12

---@type table<integer, { key: string, file: string, side: "after"|"before" }>
local attached = {}
---@type AgenticFlow.Config?
local active_config
-- The session kill switch. Off keeps the attachment map so flipping back
-- restores exactly what was showing.
local enabled = true

function M.setup_highlights()
  vim.api.nvim_set_hl(0, "AgenticFlowAdd", { default = true, link = "Added" })
  vim.api.nvim_set_hl(0, "AgenticFlowChange", { default = true, link = "Changed" })
  vim.api.nvim_set_hl(0, "AgenticFlowDelete", { default = true, link = "Removed" })
  vim.api.nvim_set_hl(0, "AgenticFlowReviewedSign", { default = true, link = "NonText" })
  vim.api.nvim_set_hl(0, "AgenticFlowComment", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "AgenticFlowStale", { default = true, link = "DiagnosticWarn" })
end

---@param buf integer
---@param line integer
---@param line_count integer
---@param glyph string
---@param group string
---@param priority integer
local function place(buf, line, line_count, glyph, group, priority)
  if line < 1 or line > line_count then
    return
  end
  vim.api.nvim_buf_set_extmark(buf, hunk_ns, line - 1, 0, {
    sign_text = glyph,
    sign_hl_group = group,
    number_hl_group = group,
    priority = priority,
  })
end

---Sign every changed line of one hunk on the after side.
---@param config AgenticFlow.Config
---@param buf integer
---@param line_count integer
---@param hunk AgenticFlow.Hunk
---@param reviewed boolean
local function decorate_hunk_after(config, buf, line_count, hunk, reviewed)
  if reviewed then
    local placed = {}
    for _, line in ipairs(hunk.changed_lines) do
      placed[line] = true
      place(buf, line, line_count, config.signs.reviewed, "AgenticFlowReviewedSign", HUNK_PRIORITY)
    end
    for _, line in ipairs(hunk.deletion_sign_anchors) do
      if not placed[line] then
        place(
          buf,
          line,
          line_count,
          config.signs.reviewed,
          "AgenticFlowReviewedSign",
          HUNK_PRIORITY
        )
      end
    end
    return
  end

  local signed = {}
  for _, line in ipairs(hunk.changed_lines) do
    local kind = hunk.line_kinds[line]
    signed[line] = true
    if kind == "add" then
      place(buf, line, line_count, config.signs.add, "AgenticFlowAdd", HUNK_PRIORITY)
    else
      place(buf, line, line_count, config.signs.change, "AgenticFlowChange", HUNK_PRIORITY)
    end
  end
  for _, line in ipairs(hunk.deletion_sign_anchors) do
    if not signed[line] then
      place(buf, line, line_count, config.signs.delete, "AgenticFlowDelete", HUNK_PRIORITY)
    end
  end
end

---Sign old-side lines for before buffers (and deleted-file scratches):
---removed lines exist here, so they get a bar sign with the delete
---highlight rather than an anchor underscore.
---@param config AgenticFlow.Config
---@param buf integer
---@param line_count integer
---@param hunk AgenticFlow.Hunk
---@param reviewed boolean
local function decorate_hunk_before(config, buf, line_count, hunk, reviewed)
  for _, line in ipairs(hunk.old_changed_lines) do
    if reviewed then
      place(buf, line, line_count, config.signs.reviewed, "AgenticFlowReviewedSign", HUNK_PRIORITY)
    elseif hunk.old_line_kinds[line] == "change" then
      place(buf, line, line_count, config.signs.change, "AgenticFlowChange", HUNK_PRIORITY)
    else
      place(buf, line, line_count, config.signs.change, "AgenticFlowDelete", HUNK_PRIORITY)
    end
  end
end

---@param comment AgenticFlow.Comment
---@return string
local function comment_label(comment)
  local first = vim.split(comment.text or "", "\n", { plain = true })[1] or ""
  first = vim.fn.strcharpart(first, 0, 48)
  return first ~= "" and first or "Comment"
end

---Comment signs and virtual text, relocated against the live buffer lines
---first so anchors follow unsaved edits. Skipped on before-side buffers —
---comments anchor to the new side.
---@param config AgenticFlow.Config
---@param context AgenticFlow.Context
---@param file string
---@param buf integer
local function decorate_comments(config, context, file, buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  review.relocate_comments(context, file, lines)

  local file_entry = context.session.files[file]
  if not file_entry then
    return
  end

  local file_comments = {}
  local line_comments = {}
  for _, comment in ipairs(file_entry.comments or {}) do
    if comment.start_line then
      local line = math.max(1, math.min(comment.start_line, math.max(1, #lines)))
      line_comments[line] = line_comments[line] or {}
      line_comments[line][#line_comments[line] + 1] = comment
    else
      file_comments[#file_comments + 1] = comment
    end
  end

  local virtual_text = config.display.virtual_text ~= false
  if #file_comments > 0 then
    vim.api.nvim_buf_set_extmark(buf, comment_ns, 0, 0, {
      virt_text = virtual_text
          and {
            {
              ("  ▣ %d file %s"):format(
                #file_comments,
                #file_comments == 1 and "note" or "notes"
              ),
              "AgenticFlowComment",
            },
          }
        or nil,
      virt_text_pos = "eol",
      priority = COMMENT_PRIORITY,
    })
  end

  for line, comments in pairs(line_comments) do
    local stale = false
    for _, comment in ipairs(comments) do
      stale = stale or comment.stale == true
    end
    local label = #comments == 1 and comment_label(comments[1]) or ("%d comments"):format(#comments)
    if stale then
      label = "stale · " .. label
    end
    local highlight = stale and "AgenticFlowStale" or "AgenticFlowComment"
    vim.api.nvim_buf_set_extmark(buf, comment_ns, line - 1, 0, {
      sign_text = stale and config.signs.stale or config.signs.comment,
      sign_hl_group = highlight,
      virt_text = virtual_text and { { "  " .. label, highlight } } or nil,
      virt_text_pos = "eol",
      priority = COMMENT_PRIORITY,
    })
  end
end

---@param buf integer
local function clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, hunk_ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(buf, comment_ns, 0, -1)
  end
end

---@param config AgenticFlow.Config
---@param context AgenticFlow.Context
---@param file string
---@param buf integer
---@param side? "after"|"before"
local function decorate(config, context, file, buf, side)
  if not enabled then
    return
  end
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  clear(buf)

  -- A file with no change entry still gets its comment markers: an
  -- **off-diff comment** is only visible if the buffer holding it decorates.
  local change = context.by_file[file]
  if change then
    local line_count = math.max(1, vim.api.nvim_buf_line_count(buf))
    -- Deleted-file buffers show the merge-base contents, so they always
    -- decorate through old-side line data.
    local old_side = side == "before" or change.status == "D"
    for _, hunk in ipairs(change.hunks or {}) do
      local reviewed = review.hunk_reviewed(context, file, hunk)
      if old_side then
        decorate_hunk_before(config, buf, line_count, hunk, reviewed)
      else
        decorate_hunk_after(config, buf, line_count, hunk, reviewed)
      end
    end
  end
  if side ~= "before" then
    decorate_comments(config, context, file, buf)
  end
end

---Decorate `buf` for `file` and keep it fresh across context refreshes.
---@param config AgenticFlow.Config
---@param context AgenticFlow.Context
---@param file string
---@param buf integer
---@param side? "after"|"before"
function M.attach(config, context, file, buf, side)
  active_config = config
  attached[buf] = { key = context.key, file = file, side = side or "after" }
  decorate(config, context, file, buf, side)
end

---@param buf integer
function M.detach(buf)
  attached[buf] = nil
  clear(buf)
end

---Remove every mark; no signs may survive a context that is gone.
---@param key? string only detach buffers attached to this context
function M.detach_all(key)
  for buf, info in pairs(attached) do
    if not key or info.key == key then
      M.detach(buf)
    end
  end
end

---Re-decorate every buffer attached to `context`'s review.
---@param context AgenticFlow.Context
function M.refresh(context)
  if not active_config then
    return
  end
  for buf, info in pairs(attached) do
    if info.key == context.key then
      if vim.api.nvim_buf_is_valid(buf) then
        decorate(active_config, context, info.file, buf, info.side)
      else
        attached[buf] = nil
      end
    end
  end
end

---Decorate a buffer nobody opened through the plugin. The context resolves in
---the background the first time a buffer from a repository shows up; a
---repository that resolves to nothing — dormant, or not a repository at all —
---stays completely silent here, because nobody asked it a question.
---@param buf integer
local function attach_ambient(buf)
  if not enabled or not active_config or active_config.display.hunk_signs == "review_only" then
    return
  end
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return
  end
  if vim.api.nvim_buf_get_name(buf) == "" then
    return
  end
  local config = active_config
  pipeline.for_buffer(config, buf, function(context)
    if not context or not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
      return
    end
    local file = util.relative(context.root, vim.api.nvim_buf_get_name(buf))
    if not file then
      return
    end
    local info = attached[buf]
    if info and info.key == context.key and info.file == file and info.side == "after" then
      return
    end
    M.attach(config, context, file, buf)
  end)
end

---Whether decoration is currently drawn at all.
---@return boolean
function M.enabled()
  return enabled
end

---Switch decoration off or back on for this session. Off strips every mark but
---keeps the attachments, so flipping back restores exactly what was showing
---plus whatever ambient buffers have appeared meanwhile. Review state is never
---touched, so the round trip is lossless.
---@param on boolean
function M.set_enabled(on)
  on = on and true or false
  if on == enabled then
    return
  end
  enabled = on
  if not enabled then
    for buf in pairs(attached) do
      clear(buf)
    end
    return
  end
  for buf, info in pairs(attached) do
    local context = active_config and pipeline.get(info.key)
    if context and vim.api.nvim_buf_is_valid(buf) then
      ---@cast active_config -nil
      decorate(active_config, context, info.file, buf, info.side)
    else
      attached[buf] = nil
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      attach_ambient(buf)
    end
  end
end

---Wire highlights and the attach/detach lifecycle to the pipeline events.
---@param config AgenticFlow.Config
function M.setup(config)
  active_config = config
  M.setup_highlights()
  local group = vim.api.nvim_create_augroup("AgenticFlowSigns", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = M.setup_highlights,
  })
  -- The ambient attach path: a file opened with `:e`, a picker, or a buffer
  -- switch decorates like one opened through the sidebar.
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
    group = group,
    callback = function(args)
      attach_ambient(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AgenticFlowContextRefreshed",
    callback = function(args)
      local context = pipeline.get(args.data.key)
      if context then
        M.refresh(context)
      end
      -- A dormant buffer may have become resolvable because an explicit
      -- command just picked a base. Re-run ambient attachment for loaded
      -- buffers so the visible file decorates without requiring a BufEnter.
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) then
          attach_ambient(buf)
        end
      end
    end,
  })
  -- A checkout moves a repository's context to a new key. Attachments name the
  -- old one, so without this every ordinary file buffer would keep decorating
  -- from the branch the user just left.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AgenticFlowContextMigrated",
    callback = function(args)
      local from, to = args.data.from, args.data.to
      local context = pipeline.get(to)
      if not context then
        return
      end
      for buf, info in pairs(attached) do
        if info.key == from then
          info.key = to
        end
      end
      M.refresh(context)
    end,
  })
  -- An evicted context can no longer answer for its decoration, so every
  -- buffer attached to it is stripped.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AgenticFlowReviewClosed",
    callback = function(args)
      M.detach_all(args.data.key)
    end,
  })
end

return M
