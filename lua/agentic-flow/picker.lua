local git = require("agentic-flow.git")
local review = require("agentic-flow.review")
local state = require("agentic-flow.state")
local util = require("agentic-flow.util")

local M = {}
local active_changes

local review_icons = {
  pending = { "○", "AgenticFlowPending" },
  partial = { "◐", "AgenticFlowPartial" },
  reviewed = { "✓", "AgenticFlowReviewed" },
  invalidated = { "↻", "AgenticFlowStale" },
}

local status_highlights = {
  A = "DiffAdd",
  C = "DiffAdd",
  D = "DiffDelete",
  M = "DiffChange",
  R = "DiffChange",
  T = "DiffChange",
  U = "DiagnosticError",
  ["?"] = "DiffAdd",
}

local function snacks()
  local ok, dependency = pcall(require, "snacks")
  if not ok or not dependency.picker or type(dependency.picker.pick) ~= "function" then
    util.notify(
      "agentic-flow.nvim requires snacks.nvim with its picker enabled",
      vim.log.levels.ERROR
    )
    return nil
  end
  return dependency
end

local function notify_error(err)
  util.notify(err or "Unknown review error", vim.log.levels.ERROR)
end

local function refresh_review_buffers(config, context, file)
  local ui = require("agentic-flow.ui")
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_valid(buf)
      and vim.api.nvim_buf_is_loaded(buf)
      and vim.b[buf].agentic_flow_root == context.root
      and (file == nil or vim.b[buf].agentic_flow_path == file)
    then
      ui.attach(config, context, vim.b[buf].agentic_flow_path, buf)
    end
  end
end

local function change_format(item)
  local icon = review_icons[item.review_status] or review_icons.pending
  local metadata = {}
  if item.hunk_count > 0 then
    metadata[#metadata + 1] = ("%d/%d %s"):format(
      item.reviewed_hunks,
      item.hunk_count,
      item.hunk_count == 1 and "chunk" or "chunks"
    )
  end
  if item.comment_count > 0 then
    metadata[#metadata + 1] = ("%d note%s"):format(
      item.comment_count,
      item.comment_count == 1 and "" or "s"
    )
  end
  local detail = #metadata > 0 and ("  " .. table.concat(metadata, " · ")) or ""
  local path = item.change.old_file and ("%s → %s"):format(item.change.old_file, item.change.file)
    or item.change.file
  return {
    { icon[1] .. " ", icon[2] },
    { item.change.status .. " ", status_highlights[item.change.status] or "Comment" },
    { path, "SnacksPickerFile" },
    { detail, item.review_status == "partial" and "AgenticFlowPartial" or "Comment" },
  }
end

local function update_change_item(item, context, change)
  local status, comment_count, reviewed_hunks, hunk_count = review.file_status(context, change.file)
  item.text = table.concat({
    status,
    change.status_label,
    change.old_file or "",
    change.file,
  }, " ")
  item.change = change
  item.review_status = status
  item.comment_count = comment_count
  item.reviewed_hunks = reviewed_hunks
  item.hunk_count = hunk_count
  item.cwd = context.root
  item.pos = { change.line or 1, 0 }
  item.preview = {
    text = change.patch ~= "" and change.patch
      or ("%s: no textual diff available"):format(change.file),
    ft = "diff",
    loc = false,
  }
  return item
end

local function update_change_items(picker, context)
  local existing = {}
  for _, item in ipairs(picker.opts.items or {}) do
    existing[item.change.file] = item
  end
  local items = {}
  for _, change in ipairs(context.changes) do
    items[#items + 1] = update_change_item(existing[change.file] or {}, context, change)
  end
  picker.opts.items = items
  local reviewed, total = review.progress(context)
  picker.title = ("Review vs %s  %d/%d"):format(context.base, reviewed, total)
  picker:refresh()
end

---@param context table
---@return boolean
function M.refresh_changes(context)
  local active = active_changes
  if
    not active
    or active.picker.closed
    or active.root ~= context.root
    or active.branch ~= context.branch
    or active.base ~= context.base
  then
    return false
  end
  active.context_ref.value = context
  local ok = pcall(update_change_items, active.picker, context)
  if not ok then
    active_changes = nil
  end
  return ok
end

local function change_actions(config, context_ref)
  return {
    agentic_toggle_reviewed = function(picker, item)
      local context = context_ref.value
      local result, err = review.toggle_reviewed(config, {
        context = context,
        file = item.change.file,
      })
      if not result then
        notify_error(err)
        return
      end
      context = result.context
      context_ref.value = context
      update_change_items(picker, context)
      refresh_review_buffers(config, context, item.change.file)
    end,
    agentic_comment = function(picker, item)
      local context = context_ref.value
      picker:close()
      vim.schedule(function()
        require("agentic-flow").add_comment({
          root = context.root,
          base = context.base,
          file = item.change.file,
        })
      end)
    end,
    agentic_base = function(picker)
      local context = context_ref.value
      picker:close()
      vim.schedule(function()
        M.select_base(config, { context = context })
      end)
    end,
    agentic_comments = function(picker)
      local context = context_ref.value
      picker:close()
      vim.schedule(function()
        M.comments(config, { context = context })
      end)
    end,
    agentic_copy = function()
      local context = context_ref.value
      local _, err, count = review.copy_comments(config, { context = context })
      if err then
        notify_error(err)
      else
        util.notify(("%d review %s copied"):format(count, count == 1 and "comment" or "comments"))
      end
    end,
  }
end

local function change_keys()
  return {
    input = {
      keys = {
        ["<c-r>"] = { "agentic_toggle_reviewed", mode = { "n", "i" } },
        ["<c-n>"] = { "agentic_comment", mode = { "n", "i" } },
        ["<c-b>"] = { "agentic_base", mode = { "n", "i" } },
        ["<c-l>"] = { "agentic_comments", mode = { "n", "i" } },
        ["<c-y>"] = { "agentic_copy", mode = { "n", "i" } },
      },
    },
    list = {
      keys = {
        r = "agentic_toggle_reviewed",
        c = "agentic_comment",
        b = "agentic_base",
        l = "agentic_comments",
        y = "agentic_copy",
      },
    },
  }
end

---Open a Snacks picker containing files changed from the active comparison base.
---@param config table
---@param opts? table
---@return table?
function M.changes(config, opts)
  opts = opts or {}
  vim.validate("config", config, "table")
  vim.validate("opts", opts, "table")
  vim.validate("opts.base", opts.base, "string", true)
  vim.validate("opts.picker", opts.picker, "table", true)

  local dependency = snacks()
  if not dependency then
    return nil
  end
  local context, err = review.resolve(config, opts)
  if not context then
    notify_error(err)
    return nil
  end

  local items = {}
  for _, change in ipairs(context.changes) do
    items[#items + 1] = update_change_item({}, context, change)
  end

  local context_ref = { value = context }
  local reviewed, total = review.progress(context)
  local picker_opts = vim.tbl_deep_extend(
    "force",
    {
      source = "agentic_flow_changes",
      title = ("Review vs %s  %d/%d"):format(context.base, reviewed, total),
      items = items,
      format = change_format,
      preview = "preview",
      focus = "list",
      auto_close = false,
      jump = { close = false },
      layout = { preset = "sidebar", preview = false },
      matcher = { sort_empty = true, filename_bonus = true },
      sort = { fields = { "score:desc", "idx" } },
      show_empty = true,
    },
    config.picker,
    opts.picker or {},
    {
      confirm = function(picker, item)
        if not item then
          return
        end
        local main = picker.main
        vim.schedule(function()
          local current_context = context_ref.value
          if main and vim.api.nvim_win_is_valid(main) then
            vim.api.nvim_set_current_win(main)
          end
          local _, open_error = review.open_change(config, current_context, item.change)
          if open_error then
            notify_error(open_error)
          end
        end)
      end,
      actions = change_actions(config, context_ref),
      win = change_keys(),
    }
  )
  local picker = dependency.picker.pick(picker_opts)
  if picker then
    active_changes = {
      picker = picker,
      context_ref = context_ref,
      root = context.root,
      branch = context.branch,
      base = context.base,
    }
  end
  return picker
end

local function branch_format(item)
  return {
    {
      item.branch.current and "* " or "  ",
      item.branch.current and "AgenticFlowReviewed" or "Comment",
    },
    { item.branch.name, "SnacksPickerFile" },
    { "  " .. item.branch.commit, "Comment" },
    { item.branch.subject ~= "" and ("  " .. item.branch.subject) or "", "Comment" },
  }
end

---Pick and remember the comparison branch without checking it out.
---@param config table
---@param opts? table
---@return table?
function M.select_base(config, opts)
  opts = opts or {}
  local dependency = snacks()
  if not dependency then
    return nil
  end

  local seed = opts.context
  local root
  if seed then
    root = seed.root
  elseif opts.root then
    root = git.root(opts.root)
  elseif opts.buf and type(vim.b[opts.buf].agentic_flow_root) == "string" then
    root = vim.b[opts.buf].agentic_flow_root
  else
    local buf = opts.buf or vim.api.nvim_get_current_buf()
    local name = vim.api.nvim_buf_get_name(buf)
    root = git.root(name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd())
    if not root then
      seed = review.active()
      root = seed and seed.root or nil
    end
  end
  if not root then
    notify_error("not inside a Git repository")
    return nil
  end
  local branch = git.branch(root)
  local current_base = seed and seed.base or state.remembered_base(root, branch) or config.base
  local branches, err = git.branches(root)
  if not branches then
    notify_error(err)
    return nil
  end

  local items = {}
  for _, candidate in ipairs(branches) do
    items[#items + 1] = {
      text = table.concat({ candidate.name, candidate.commit, candidate.subject }, " "),
      branch = candidate,
    }
  end

  local picker_opts = vim.tbl_deep_extend(
    "force",
    {
      source = "agentic_flow_bases",
      title = "Comparison base · " .. current_base,
      items = items,
      format = branch_format,
      preview = false,
      sort = { fields = { "score:desc", "idx" } },
    },
    config.branch_picker,
    opts.picker or {},
    {
      confirm = function(picker, item)
        picker:close()
        local ok, remember_error = state.remember_base(root, branch, item.branch.name)
        if not ok then
          notify_error(remember_error)
          return
        end
        vim.schedule(function()
          M.changes(config, { root = root, base = item.branch.name })
        end)
      end,
    }
  )
  return dependency.picker.pick(picker_opts)
end

local function range_label(comment)
  if not comment.start_line then
    return comment.path
  end
  if comment.start_line == comment.end_line then
    return ("%s:%d"):format(comment.path, comment.start_line)
  end
  return ("%s:%d-%d"):format(comment.path, comment.start_line, comment.end_line)
end

local function comment_format(item)
  local flags = {}
  if item.comment.stale then
    flags[#flags + 1] = "stale"
  end
  if item.comment.orphan then
    flags[#flags + 1] = "orphan"
  end
  local status = #flags > 0 and ("  [%s]"):format(table.concat(flags, ", ")) or ""
  local first = vim.split(item.comment.text, "\n", { plain = true })[1] or ""
  return {
    { range_label(item.comment), "SnacksPickerFile" },
    { status, #flags > 0 and "AgenticFlowStale" or "Comment" },
    { "  " .. first, "Comment" },
  }
end

local function comment_preview(comment)
  local lines = {
    "# " .. range_label(comment),
    "",
  }
  if comment.stale or comment.orphan then
    local flags = {}
    if comment.stale then
      flags[#flags + 1] = "stale anchor"
    end
    if comment.orphan then
      flags[#flags + 1] = "file no longer changed"
    end
    lines[#lines + 1] = "**" .. table.concat(flags, " · ") .. "**"
    lines[#lines + 1] = ""
  end
  vim.list_extend(lines, vim.split(comment.text, "\n", { plain = true }))
  if comment.anchor and #(comment.anchor.lines or {}) > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "```"
    vim.list_extend(lines, comment.anchor.lines)
    lines[#lines + 1] = "```"
  end
  return table.concat(lines, "\n")
end

local function comment_actions(config, context)
  return {
    agentic_edit_comment = function(picker, item)
      picker:close()
      vim.schedule(function()
        require("agentic-flow").edit_comment(item.comment, context)
      end)
    end,
    agentic_delete_comment = function(picker, item)
      local ok, err = review.delete_comment(config, {
        context = context,
        id = item.comment.id,
      })
      if not ok then
        notify_error(err)
        return
      end
      refresh_review_buffers(config, context, item.comment.path)
      picker:close()
      vim.schedule(function()
        M.comments(config, { root = context.root, base = context.base })
      end)
    end,
    agentic_clear_comments = function(picker)
      vim.ui.select({ "Clear all comments", "Cancel" }, {
        prompt = "Clear every comment in this review?",
      }, function(choice)
        if choice ~= "Clear all comments" then
          return
        end
        local ok, err = review.clear_comments(config, { context = context })
        if not ok then
          notify_error(err)
          return
        end
        refresh_review_buffers(config, context)
        picker:close()
        util.notify("All review comments cleared")
      end)
    end,
    agentic_copy = function()
      local _, err, count = review.copy_comments(config, { context = context })
      if err then
        notify_error(err)
      else
        util.notify(("%d review %s copied"):format(count, count == 1 and "comment" or "comments"))
      end
    end,
  }
end

---List all comments in the active review.
---@param config table
---@param opts? table
---@return table?
function M.comments(config, opts)
  opts = opts or {}
  local dependency = snacks()
  if not dependency then
    return nil
  end
  local seed = opts.context
  local context, err = review.resolve(config, {
    root = seed and seed.root or opts.root,
    base = seed and seed.base or opts.base,
    buf = opts.buf,
  })
  if not context then
    notify_error(err)
    return nil
  end

  local items = {}
  for _, comment in ipairs(review.comments(context)) do
    items[#items + 1] = {
      text = range_label(comment) .. " " .. comment.text,
      comment = comment,
      pos = { comment.start_line or 1, 0 },
      preview = { text = comment_preview(comment), ft = "markdown", loc = false },
    }
  end

  local picker_opts = vim.tbl_deep_extend(
    "force",
    {
      source = "agentic_flow_comments",
      title = ("%d review %s · %s"):format(
        #items,
        #items == 1 and "comment" or "comments",
        context.base
      ),
      items = items,
      format = comment_format,
      preview = "preview",
      show_empty = true,
      sort = { fields = { "idx" } },
    },
    config.comments_picker,
    opts.picker or {},
    {
      confirm = function(picker, item)
        picker:close()
        vim.schedule(function()
          local _, open_error = review.open_comment(config, context, item.comment)
          if open_error then
            notify_error(open_error)
          end
        end)
      end,
      actions = comment_actions(config, context),
      win = {
        input = {
          keys = {
            ["<c-e>"] = { "agentic_edit_comment", mode = { "n", "i" } },
            ["<c-d>"] = { "agentic_delete_comment", mode = { "n", "i" } },
            ["<c-x>"] = { "agentic_clear_comments", mode = { "n", "i" } },
            ["<c-y>"] = { "agentic_copy", mode = { "n", "i" } },
          },
        },
        list = {
          keys = {
            e = "agentic_edit_comment",
            d = "agentic_delete_comment",
            D = "agentic_clear_comments",
            y = "agentic_copy",
          },
        },
      },
    }
  )
  return dependency.picker.pick(picker_opts)
end

return M
