local review = require("agentic-flow.review")
local util = require("agentic-flow.util")

local M = {}

local namespace = vim.api.nvim_create_namespace("agentic-flow-comments")

local function comment_label(comment)
  local first = vim.split(comment.text or "", "\n", { plain = true })[1] or ""
  first = vim.fn.strcharpart(first, 0, 48)
  return first ~= "" and first or "Comment"
end

local function decorate(config, context, file, buf)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end

  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
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
    vim.api.nvim_buf_set_extmark(buf, namespace, 0, 0, {
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
      priority = 90,
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
    vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, {
      sign_text = stale and config.signs.stale or config.signs.comment,
      sign_hl_group = highlight,
      virt_text = virtual_text and { { "  " .. label, highlight } } or nil,
      virt_text_pos = "eol",
      priority = 100,
    })
  end
end

---@param config table
---@param context table
---@param file string
---@param buf number
function M.attach(config, context, file, buf)
  vim.b[buf].agentic_flow_root = context.root
  vim.b[buf].agentic_flow_base = context.base
  vim.b[buf].agentic_flow_path = file
  decorate(config, context, file, buf)
end

---@param opts table
---@return number
function M.comment_editor(opts)
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

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = save_comment,
  })
  vim.keymap.set({ "n", "i" }, "<C-s>", save_comment, {
    buffer = buf,
    desc = "Save review note",
    silent = true,
  })
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

function M.setup_highlights()
  vim.api.nvim_set_hl(0, "AgenticFlowComment", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "AgenticFlowStale", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "AgenticFlowReviewed", { default = true, link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "AgenticFlowPending", { default = true, link = "Comment" })
end

return M
