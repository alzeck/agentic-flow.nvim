local review = require("agentic-flow.review")
local ui = require("agentic-flow.ui")
local util = require("agentic-flow.util")

local M = {}

local defaults = {
  base = "origin/main",
  clipboard = "+",
  picker = {},
  branch_picker = {},
  comments_picker = {},
  signs = {
    comment = "●",
    stale = "!",
    unreviewed = "▎",
  },
  display = {
    virtual_text = true,
    unreviewed_chunks = true,
  },
}
local config = vim.deepcopy(defaults)

local function notify_error(err)
  util.notify(err or "Unknown review error", vim.log.levels.ERROR)
end

local function refresh_buffer(buf)
  if
    not vim.api.nvim_buf_is_valid(buf)
    or type(vim.b[buf].agentic_flow_root) ~= "string"
    or type(vim.b[buf].agentic_flow_base) ~= "string"
  then
    return
  end
  local context = review.resolve(config, {
    root = vim.b[buf].agentic_flow_root,
    base = vim.b[buf].agentic_flow_base,
    buf = buf,
  })
  if context then
    ui.attach(config, context, vim.b[buf].agentic_flow_path, buf)
    require("agentic-flow.picker").refresh_changes(context)
  end
end

local function refresh_context_buffers(context, file)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_valid(buf)
      and vim.api.nvim_buf_is_loaded(buf)
      and vim.b[buf].agentic_flow_root == context.root
      and vim.b[buf].agentic_flow_path == file
    then
      ui.attach(config, context, file, buf)
    end
  end
end

local function setup_autocommands()
  local group = vim.api.nvim_create_augroup("AgenticFlow", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = ui.setup_highlights,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(args)
      vim.schedule(function()
        refresh_buffer(args.buf)
      end)
    end,
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      local buf = vim.api.nvim_get_current_buf()
      vim.schedule(function()
        refresh_buffer(buf)
      end)
    end,
  })
end

---Configure agentic-flow.nvim.
---@param opts? table
function M.setup(opts)
  opts = opts or {}
  vim.validate("opts", opts, "table")
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  vim.validate("base", config.base, "string")
  vim.validate("clipboard", config.clipboard, "string")
  vim.validate("picker", config.picker, "table")
  vim.validate("branch_picker", config.branch_picker, "table")
  vim.validate("comments_picker", config.comments_picker, "table")
  vim.validate("signs", config.signs, "table")
  vim.validate("display", config.display, "table")
  ui.setup_highlights()
  setup_autocommands()
end

---Return a copy of the active configuration.
---@return table
function M.get_config()
  return vim.deepcopy(config)
end

---Open the changed-files picker.
---@param opts? table
---@return table?
function M.changes(opts)
  return require("agentic-flow.picker").changes(config, opts)
end

---Pick the comparison base without checking it out.
---@param opts? table
---@return table?
function M.select_base(opts)
  return require("agentic-flow.picker").select_base(config, opts)
end

---Toggle reviewed state for the current or specified file.
---@param opts? table
---@return table?
function M.toggle_reviewed(opts)
  local result, err = review.toggle_reviewed(config, opts or {})
  if not result then
    notify_error(err)
    return nil
  end
  util.notify(
    ("%s is %s"):format(result.file, result.status == "reviewed" and "reviewed" or "back in review")
  )
  refresh_context_buffers(result.context, result.file)
  require("agentic-flow.picker").refresh_changes(result.context)
  return result
end

---Toggle reviewed state for the chunk under the cursor.
---@param opts? table
---@return table?
function M.toggle_chunk_reviewed(opts)
  local result, err = review.toggle_chunk_reviewed(config, opts or {})
  if not result then
    notify_error(err)
    return nil
  end
  local action = result.status == "reviewed" and "Chunk reviewed" or "Chunk returned to review"
  util.notify(("%s · %d/%d chunks reviewed"):format(action, result.reviewed, result.total))
  refresh_context_buffers(result.context, result.file)
  require("agentic-flow.picker").refresh_changes(result.context)
  return result
end

local function navigate_unreviewed(direction, opts)
  opts = opts or {}
  if not opts.context then
    local active = review.active()
    local buf = opts.buf or vim.api.nvim_get_current_buf()
    if
      active
      and vim.b[buf].agentic_flow_root == active.root
      and vim.b[buf].agentic_flow_base == active.base
    then
      opts = vim.tbl_extend("force", {}, opts, { context = active })
    end
  end
  local result, err = review.navigate_unreviewed(config, opts, direction)
  if not result then
    notify_error(err)
    return nil
  end
  return result
end

---Open the next unreviewed chunk, wrapping across files.
---@param opts? table
---@return table?
function M.next_unreviewed(opts)
  return navigate_unreviewed("next", opts)
end

---Open the previous unreviewed chunk, wrapping across files.
---@param opts? table
---@return table?
function M.prev_unreviewed(opts)
  return navigate_unreviewed("previous", opts)
end

local function comment_file(context, opts)
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

local function comment_label(file, start_line, end_line)
  if not start_line then
    return file
  end
  if start_line == end_line then
    return ("%s:%d"):format(file, start_line)
  end
  return ("%s:%d-%d"):format(file, start_line, end_line)
end

local function buffer_cursor_line(buf)
  if vim.api.nvim_get_current_buf() == buf then
    return vim.api.nvim_win_get_cursor(0)[1]
  end
  local windows = vim.fn.win_findbuf(buf)
  return #windows > 0 and vim.api.nvim_win_get_cursor(windows[1])[1] or 1
end

---Add a current-line, selected-line, or explicitly file-level comment.
---@param opts? table
---@return table|number?
function M.add_comment(opts)
  opts = opts or {}
  local source_buf = opts.buf or vim.api.nvim_get_current_buf()
  if
    opts.start_line == nil
    and opts.end_line == nil
    and opts.file_level ~= true
    and opts.file == nil
  then
    local line = buffer_cursor_line(source_buf)
    opts = vim.tbl_extend("force", opts, {
      start_line = line,
      end_line = line,
    })
  end
  local context, err = review.resolve(config, opts)
  if not context then
    notify_error(err)
    return nil
  end
  local file = comment_file(context, opts)
  if not file then
    notify_error("Could not determine the file for this comment")
    return nil
  end

  local anchor_buf = opts.buf
  if not anchor_buf then
    local source_path = vim.api.nvim_buf_get_name(source_buf)
    local source_file = vim.b[source_buf].agentic_flow_path
    if
      source_file == file
      or (source_path ~= "" and util.relative(context.root, source_path) == file)
    then
      anchor_buf = source_buf
    end
  end
  local create_opts = vim.tbl_extend("force", opts, {
    context = context,
    file = file,
    buf = anchor_buf,
  })
  if opts.text then
    local comment, create_error, updated = review.create_comment(config, create_opts)
    if not comment then
      notify_error(create_error)
      return nil
    end
    updated = assert(updated)
    if vim.api.nvim_buf_is_valid(source_buf) and vim.b[source_buf].agentic_flow_path == file then
      ui.attach(config, updated, file, source_buf)
    end
    return comment
  end

  return ui.comment_editor({
    label = comment_label(file, opts.start_line, opts.end_line),
    on_save = function(text)
      create_opts.text = text
      local comment, create_error, updated = review.create_comment(config, create_opts)
      if not comment then
        return false, create_error
      end
      updated = assert(updated)
      util.notify("Review comment added")
      if vim.api.nvim_buf_is_valid(source_buf) and vim.b[source_buf].agentic_flow_path == file then
        ui.attach(config, updated, file, source_buf)
      end
      return true
    end,
  })
end

---Edit an existing comment.
---@param comment table
---@param context table
---@param opts? table
---@return table|number?
function M.edit_comment(comment, context, opts)
  opts = opts or {}
  local function refresh_comment_buffers(updated_context)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if
        vim.api.nvim_buf_is_valid(buf)
        and vim.api.nvim_buf_is_loaded(buf)
        and vim.b[buf].agentic_flow_root == updated_context.root
        and vim.b[buf].agentic_flow_path == comment.path
      then
        ui.attach(config, updated_context, comment.path, buf)
      end
    end
  end
  if opts.text then
    local updated, err, updated_context = review.update_comment(config, {
      context = context,
      id = comment.id,
      text = opts.text,
    })
    if not updated then
      notify_error(err)
    elseif updated_context then
      refresh_comment_buffers(updated_context)
    end
    return updated
  end
  return ui.comment_editor({
    id = comment.id,
    label = comment_label(comment.path, comment.start_line, comment.end_line),
    text = comment.text,
    on_save = function(text)
      local updated, err, updated_context = review.update_comment(config, {
        context = context,
        id = comment.id,
        text = text,
      })
      if not updated then
        return false, err
      end
      if updated_context then
        refresh_comment_buffers(updated_context)
      end
      util.notify("Review comment updated")
      return true
    end,
  })
end

---Open the comments picker.
---@param opts? table
---@return table?
function M.comments(opts)
  return require("agentic-flow.picker").comments(config, opts)
end

---Copy all comments in the active review.
---@param opts? table
---@return string?
function M.copy_comments(opts)
  local output, err, count = review.copy_comments(config, opts or {})
  if not output then
    notify_error(err)
    return nil
  end
  util.notify(("%d review %s copied"):format(count, count == 1 and "comment" or "comments"))
  return output
end

return M
