local git = require("agentic-flow.git")
local pipeline = require("agentic-flow.pipeline")
local review = require("agentic-flow.review")
local signs = require("agentic-flow.signs")
local util = require("agentic-flow.util")

local M = {}

---@class AgenticFlow.CommentEditorOptions
---@field id? string|integer
---@field label string
---@field text? string
---@field on_save fun(text: string): boolean?, string?
---@field on_copy? fun(text: string): boolean?, string?

---@class AgenticFlow.CommentDraft
---@field file string
---@field start_line? integer
---@field end_line? integer
---@field lines? string[]

local namespace = vim.api.nvim_create_namespace("agentic-flow-comments-list")
---@type { buf: integer?, win: integer?, return_win: integer?, key: string?, config: AgenticFlow.Config?, rows: table<integer, AgenticFlow.Comment> }
local list = {
  buf = nil,
  win = nil,
  return_win = nil,
  key = nil,
  config = nil,
  rows = {},
}

---@param buf integer?
---@return boolean
local function valid_buf(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

---@param win integer?
---@return boolean
local function valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

---@param err string?
local function notify_error(err)
  util.notify(err or "Unknown comments error", vim.log.levels.ERROR)
end

---@param comment { path: string, start_line?: integer, end_line?: integer }
---@return string
local function range_label(comment)
  if not comment.start_line then
    return comment.path
  end
  if comment.start_line == comment.end_line then
    return ("%s:%d"):format(comment.path, comment.start_line)
  end
  return ("%s:%d-%d"):format(comment.path, comment.start_line, comment.end_line)
end

---@param comment AgenticFlow.Comment
---@return string
local function flags(comment)
  local labels = {}
  if comment.stale then
    labels[#labels + 1] = "stale"
  end
  if comment.orphan then
    labels[#labels + 1] = "orphan"
  end
  return #labels > 0 and (" [%s]"):format(table.concat(labels, ", ")) or ""
end

---@return AgenticFlow.Comment?
local function selected_comment()
  if not valid_win(list.win) then
    return nil
  end
  return list.rows[vim.api.nvim_win_get_cursor(list.win)[1]]
end

local function setup_highlights()
  vim.api.nvim_set_hl(0, "AgenticFlowCommentsTitle", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "AgenticFlowCommentsPath", { default = true, link = "Directory" })
  vim.api.nvim_set_hl(0, "AgenticFlowCommentsFlag", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "AgenticFlowCommentsPreview", { default = true, link = "Comment" })
end

---@param line integer
---@param start_col integer
---@param end_col integer
---@param group string
local function mark(line, start_col, end_col, group)
  if end_col > start_col then
    vim.api.nvim_buf_set_extmark(list.buf, namespace, line - 1, start_col, {
      end_col = end_col,
      hl_group = group,
    })
  end
end

local function render()
  if not valid_buf(list.buf) then
    return
  end
  local context = pipeline.get(list.key)
  if not context then
    return
  end

  local anchor = selected_comment()
  local anchor_id = anchor and tostring(anchor.id) or nil
  local comments = review.comments(context)
  local lines = {
    ("%d review %s · %s"):format(
      #comments,
      #comments == 1 and "comment" or "comments",
      context.base
    ),
    "",
  }
  local rows = {}
  local highlights = {
    { line = 1, start_col = 0, end_col = #lines[1], group = "AgenticFlowCommentsTitle" },
  }
  local anchor_line

  for _, comment in ipairs(comments) do
    local label = range_label(comment)
    local status = flags(comment)
    local comment_lines = vim.split(comment.text or "", "\n", { plain = true })
    local first = comment_lines[1] or ""
    lines[#lines + 1] = label .. status .. "  " .. first
    local line = #lines
    rows[line] = comment
    if anchor_id and tostring(comment.id) == anchor_id and not anchor_line then
      anchor_line = line
    end
    highlights[#highlights + 1] =
      { line = line, start_col = 0, end_col = #label, group = "AgenticFlowCommentsPath" }
    if status ~= "" then
      highlights[#highlights + 1] = {
        line = line,
        start_col = #label,
        end_col = #label + #status,
        group = "AgenticFlowCommentsFlag",
      }
    end
    for index = 2, #comment_lines do
      local preview = "  │ " .. comment_lines[index]
      lines[#lines + 1] = preview
      rows[#lines] = comment
      highlights[#highlights + 1] = {
        line = #lines,
        start_col = 0,
        end_col = #preview,
        group = "AgenticFlowCommentsPreview",
      }
    end
  end

  if #comments == 0 then
    lines[#lines + 1] = "No review comments"
    highlights[#highlights + 1] = {
      line = #lines,
      start_col = 0,
      end_col = #lines[#lines],
      group = "AgenticFlowCommentsPreview",
    }
  end

  vim.bo[list.buf].modifiable = true
  vim.api.nvim_buf_set_lines(list.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(list.buf, namespace, 0, -1)
  for _, highlight in ipairs(highlights) do
    mark(highlight.line, highlight.start_col, highlight.end_col, highlight.group)
  end
  vim.bo[list.buf].modifiable = false
  list.rows = rows
  if valid_win(list.win) then
    local current = vim.api.nvim_win_get_cursor(list.win)[1]
    vim.api.nvim_win_set_cursor(list.win, { anchor_line or math.min(current, #lines), 0 })
  end
end

---Open the multiline markdown editor.
---@param opts AgenticFlow.CommentEditorOptions
---@return integer
function M.editor(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  local name = ("agentic-flow://comment/%s"):format(opts.id or "new")
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"

  local lines = vim.split(opts.text or "", "\n", { plain = true })
  if #lines == 0 then
    lines = { "" }
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false

  local width = math.max(1, math.min(72, vim.o.columns - 4))
  local height = math.max(3, math.min(math.max(5, #lines + 2), vim.o.lines - 4))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = (" Review note · %s "):format(opts.label),
    title_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local function save_comment()
    local contents = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    if not contents:match("%S") then
      util.notify("Comments cannot be empty", vim.log.levels.WARN)
      return
    end
    local ok, err = opts.on_save(contents)
    if ok == false then
      util.notify(err or "Could not save comment", vim.log.levels.ERROR)
      return
    end
    vim.bo[buf].modified = false
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  -- Copying yields the note without persisting it, so it never runs on_save.
  local function copy_comment()
    local contents = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    if not contents:match("%S") then
      util.notify("Comments cannot be empty", vim.log.levels.WARN)
      return
    end
    local ok, err = opts.on_copy(contents)
    if ok == false then
      util.notify(err or "Could not copy comment", vim.log.levels.ERROR)
      return
    end
    vim.bo[buf].modified = false
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = save_comment,
  })
  vim.keymap.set({ "n", "i" }, "<C-s>", save_comment, {
    buffer = buf,
    desc = "Save review note",
    silent = true,
  })
  if opts.on_copy then
    vim.keymap.set({ "n", "i" }, "<C-y>", copy_comment, {
      buffer = buf,
      desc = "Copy review note",
      silent = true,
    })
  end
  vim.keymap.set("n", "q", function()
    if vim.bo[buf].modified then
      util.notify("Save with :write or discard with :q!", vim.log.levels.WARN)
      return
    end
    vim.api.nvim_win_close(win, true)
  end, {
    buffer = buf,
    desc = "Close review note",
    silent = true,
  })
  vim.cmd.startinsert()
  return buf
end

---@param config AgenticFlow.Config
---@param context AgenticFlow.Context
---@param opts AgenticFlow.CommentDraft
---@return integer
function M.create(config, context, opts)
  local label = range_label({
    path = opts.file,
    start_line = opts.start_line,
    end_line = opts.end_line,
  })
  local key = context.key
  local register = config.clipboard
  return M.editor({
    label = label,
    on_copy = function(text)
      vim.fn.setreg(register, "@" .. label .. " : " .. text)
      util.notify("Review comment copied")
      return true
    end,
    on_save = function(text)
      if not pipeline.get(key) then
        return false, "the review context is no longer cached"
      end
      local create_opts = vim.tbl_extend("force", opts, { text = text })
      local comment, err = pipeline.create_comment(key, create_opts)
      if not comment then
        return false, err
      end
      util.notify("Review comment added")
      return true
    end,
  })
end

---Edit the comment under the list cursor.
---@return integer?
function M.edit()
  local comment = selected_comment()
  if not comment then
    return nil
  end
  local key = list.key
  local label = range_label(comment)
  local register = list.config.clipboard
  return M.editor({
    id = comment.id,
    label = label,
    text = comment.text,
    on_copy = function(text)
      vim.fn.setreg(register, "@" .. label .. " : " .. text)
      util.notify("Review comment copied")
      return true
    end,
    on_save = function(text)
      if not pipeline.get(key) then
        return false, "the review context is no longer cached"
      end
      local updated, err = pipeline.update_comment(key, { id = comment.id, text = text })
      if not updated then
        return false, err
      end
      util.notify("Review comment updated")
      return true
    end,
  })
end

---@return integer?
local function source_window()
  if valid_win(list.return_win) then
    return list.return_win
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= list.win then
      return win
    end
  end
end

---@param context AgenticFlow.Context
---@param comment AgenticFlow.Comment
---@param buf integer
local function finish_jump(context, comment, buf)
  local win = source_window()
  if not win or not valid_buf(buf) then
    return
  end
  vim.api.nvim_win_set_buf(win, buf)
  vim.b[buf].agentic_flow_root = context.root
  vim.b[buf].agentic_flow_branch = context.branch
  vim.b[buf].agentic_flow_base = context.base
  vim.b[buf].agentic_flow_path = comment.path
  ---@diagnostic disable-next-line: param-type-mismatch
  signs.attach(list.config, context, comment.path, buf)
  local line =
    math.max(1, math.min(comment.start_line or 1, math.max(1, vim.api.nvim_buf_line_count(buf))))
  vim.api.nvim_win_set_cursor(win, { line, 0 })
  vim.api.nvim_set_current_win(win)
end

---Jump to the selected comment's current (possibly relocated) location.
function M.jump()
  local comment = selected_comment()
  local context = pipeline.get(list.key)
  if not comment or not context then
    return
  end
  if comment.orphan then
    return util.notify("The commented file is no longer in this review", vim.log.levels.WARN)
  end
  local diff = package.loaded["agentic-flow.diff"]
  if type(diff) == "table" and diff.is_open and diff.is_open() then
    diff.retarget(list.config, context, comment.path, comment.start_line or 1)
    return
  end
  local change = context.by_file[comment.path]
  if change and change.status == "D" then
    git.file_at(
      context.root,
      context.merge_base,
      change.old_file or comment.path,
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
          finish_jump(context, comment, buf)
        end)
      end
    )
    return
  end
  local buf = vim.fn.bufadd(util.absolute(context.root, comment.path))
  vim.fn.bufload(buf)
  finish_jump(context, comment, buf)
end

---Delete the selected comment.
---@return boolean?
function M.delete()
  local comment = selected_comment()
  if not comment or not list.key then
    return nil
  end
  local ok, err = pipeline.delete_comment(list.key, comment.id)
  if not ok then
    notify_error(err)
    return nil
  end
  util.notify("Review comment deleted")
  return true
end

---Clear every comment after explicit confirmation. The key is captured before
---the prompt so a list closed mid-confirmation clears nothing else.
function M.clear()
  local key = list.key
  if not pipeline.get(key) then
    return
  end
  vim.ui.select({ "Clear all comments", "Cancel" }, {
    prompt = "Clear every comment in this review?",
  }, function(choice)
    if choice ~= "Clear all comments" then
      return
    end
    local ok, err = pipeline.clear_comments(key)
    if not ok then
      return notify_error(err)
    end
    util.notify("All review comments cleared")
  end)
end

---Copy all comments to the configured register.
---@return string?
function M.copy()
  local context = pipeline.get(list.key)
  if not context then
    return nil
  end
  local output, err, count = review.copy_comments(context, list.config.clipboard)
  if not output then
    ---@cast err string
    util.notify(err, vim.log.levels.WARN)
    return nil
  end
  util.notify(("%d review %s copied"):format(count, count == 1 and "comment" or "comments"))
  return output
end

---@param buf integer
local function setup_keymaps(buf)
  local mappings = {
    ["<CR>"] = M.jump,
    e = M.edit,
    d = M.delete,
    D = M.clear,
    y = M.copy,
    q = M.close,
  }
  for lhs, callback in pairs(mappings) do
    vim.keymap.set("n", lhs, callback, { buffer = buf, silent = true, nowait = true })
  end
end

local function ensure_events()
  local group = vim.api.nvim_create_augroup("AgenticFlowCommentsUi", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = setup_highlights,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AgenticFlowContextRefreshed",
    callback = function(args)
      if list.key and args.data and args.data.key == list.key then
        render()
      end
    end,
  })
  -- A checkout re-keys the context the list is showing. Comments are scoped to
  -- a `(branch, base)` session, so following the key is what swaps the list to
  -- the branch on disk instead of pinning it to the one that is gone.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AgenticFlowContextMigrated",
    callback = function(args)
      if list.key and args.data and args.data.from == list.key then
        list.key = args.data.to
        render()
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AgenticFlowReviewClosed",
    callback = function(args)
      if list.key and args.data and args.data.key == list.key then
        M.close()
      end
    end,
  })
end

---Open the comments list in a short bottom split.
---@param config AgenticFlow.Config
---@param context AgenticFlow.Context
---@return integer
function M.open(config, context)
  if valid_win(list.win) then
    list.config = config
    list.key = context.key
    render()
    vim.api.nvim_set_current_win(list.win)
    return list.buf
  end
  list.config = config
  list.key = context.key
  list.return_win = vim.api.nvim_get_current_win()
  setup_highlights()
  ensure_events()
  vim.cmd("botright 12new")
  list.win = vim.api.nvim_get_current_win()
  list.buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(list.buf, "agentic-flow://comments")
  vim.bo[list.buf].buftype = "nofile"
  vim.bo[list.buf].bufhidden = "wipe"
  vim.bo[list.buf].swapfile = false
  vim.bo[list.buf].modifiable = false
  vim.bo[list.buf].filetype = "agentic-flow-comments"
  vim.wo[list.win].number = false
  vim.wo[list.win].relativenumber = false
  vim.wo[list.win].signcolumn = "no"
  vim.wo[list.win].wrap = false
  vim.wo[list.win].cursorline = true
  setup_keymaps(list.buf)
  render()
  return list.buf
end

---@return boolean
function M.is_open()
  return valid_win(list.win)
end

---@return integer?
function M.buf()
  return valid_buf(list.buf) and list.buf or nil
end

---@return integer?
function M.win()
  return valid_win(list.win) and list.win or nil
end

function M.close()
  local win = list.win
  list.key = nil
  list.rows = {}
  if valid_win(win) then
    ---@cast win -nil
    vim.api.nvim_win_close(win, true)
  end
  list.buf = nil
  list.win = nil
  list.return_win = nil
end

return M
