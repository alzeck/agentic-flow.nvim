local git = require("agentic-flow.git")
local state = require("agentic-flow.state")
local util = require("agentic-flow.util")

local M = {}

local active_context

local function save(context)
  local ok, err = state.save(context.root, context.session)
  if not ok then
    util.notify("Could not save review state: " .. (err or "unknown error"), vim.log.levels.ERROR)
  end
  return ok
end

local function candidate_cwd(opts)
  if opts and opts.root then
    return opts.root
  end
  local buf = opts and opts.buf or vim.api.nvim_get_current_buf()
  local stored_root = vim.b[buf].agentic_flow_root
  if type(stored_root) == "string" and stored_root ~= "" then
    return stored_root
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name ~= "" and not name:match("^agentic%-flow://") then
    return vim.fs.dirname(name)
  end
  return vim.fn.getcwd()
end

local function entry(session, file)
  session.files[file] = session.files[file] or { comments = {} }
  session.files[file].comments = session.files[file].comments or {}
  return session.files[file]
end

local function sync_session(context)
  local changed = false
  local active = {}
  for _, change in ipairs(context.changes) do
    active[change.file] = true
    if
      change.old_file
      and context.session.files[change.old_file]
      and not context.session.files[change.file]
    then
      context.session.files[change.file] = context.session.files[change.old_file]
      context.session.files[change.old_file] = nil
      for _, comment in ipairs(context.session.files[change.file].comments or {}) do
        comment.path = change.file
      end
      changed = true
    end

    local file_entry = context.session.files[change.file]
    if file_entry and file_entry.reviewed and file_entry.fingerprint ~= change.fingerprint then
      file_entry.reviewed = false
      file_entry.invalidated = true
      changed = true
    end
  end
  for file, file_entry in pairs(context.session.files) do
    if not active[file] and file_entry.reviewed then
      file_entry.reviewed = false
      file_entry.invalidated = true
      changed = true
    end
  end
  if changed then
    save(context)
  end
end

---@param config table
---@param opts? table
---@return table?, string?
function M.resolve(config, opts)
  opts = opts or {}
  local root, root_error = git.root(candidate_cwd(opts))
  if not root then
    return nil, root_error or "not inside a Git repository"
  end

  local branch = git.branch(root)
  local base = opts.base or state.remembered_base(root, branch) or config.base
  local valid, ref_error = git.validate_ref(root, base)
  if not valid then
    return nil, ("invalid comparison base %q: %s"):format(base, ref_error or "not found")
  end

  local merge_base, merge_error = git.merge_base(root, base)
  if not merge_base then
    return nil,
      ("could not find a merge-base with %q: %s"):format(base, merge_error or "unknown error")
  end

  local changes, changes_error = git.changes(root, merge_base)
  if not changes then
    return nil, changes_error
  end

  local session, session_error = state.load(root, branch, base)
  local context = {
    root = root,
    branch = branch,
    base = base,
    merge_base = merge_base,
    changes = changes,
    by_file = {},
    session = session,
  }
  for _, change in ipairs(changes) do
    context.by_file[change.file] = change
  end

  sync_session(context)
  for file, file_entry in pairs(context.session.files) do
    if #(file_entry.comments or {}) > 0 then
      local contents
      local absolute = util.absolute(root, file)
      if vim.uv.fs_stat(absolute) then
        contents = util.read_file(absolute)
      elseif context.by_file[file] and context.by_file[file].status == "D" then
        contents = git.file_at(root, merge_base, context.by_file[file].old_file or file)
      end
      if contents and not contents:find("\0", 1, true) then
        M.relocate_comments(context, file, util.split_lines(contents))
      end
    end
  end
  if opts.remember_base then
    local remembered, remember_error = state.remember_base(root, branch, base)
    if not remembered then
      util.notify(
        "Could not remember comparison base: " .. (remember_error or "unknown error"),
        vim.log.levels.WARN
      )
    end
  end
  if session_error then
    util.notify(session_error, vim.log.levels.WARN)
  end
  active_context = context
  return context
end

function M.active()
  return active_context
end

---@param context table
---@param file string
---@return string, number
function M.file_status(context, file)
  local file_entry = context.session.files[file]
  if file_entry and file_entry.reviewed then
    return "reviewed", #(file_entry.comments or {})
  end
  if file_entry and file_entry.invalidated then
    return "invalidated", #(file_entry.comments or {})
  end
  return "pending", file_entry and #(file_entry.comments or {}) or 0
end

---@param context table
---@return number, number
function M.progress(context)
  local reviewed = 0
  for _, change in ipairs(context.changes) do
    if M.file_status(context, change.file) == "reviewed" then
      reviewed = reviewed + 1
    end
  end
  return reviewed, #context.changes
end

local function current_file(context, opts)
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

local function modified_buffer(context, file)
  local absolute = util.absolute(context.root, file)
  local buf = vim.fn.bufnr(absolute)
  if buf > 0 and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
    return true
  end
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_valid(candidate)
      and vim.b[candidate].agentic_flow_root == context.root
      and vim.b[candidate].agentic_flow_path == file
      and vim.bo[candidate].modified
    then
      return true
    end
  end
  return false
end

---@param config table
---@param opts? table
---@return table?, string?
function M.toggle_reviewed(config, opts)
  opts = opts or {}
  local seed = opts.context
  local context, err = M.resolve(config, {
    root = seed and seed.root or opts.root,
    base = seed and seed.base or opts.base,
    buf = opts.buf,
  })
  if not context then
    return nil, err
  end

  local file = current_file(context, opts)
  local change = file and context.by_file[file] or nil
  if not change then
    return nil, "the current file is not part of this review"
  end

  local file_entry = entry(context.session, file)
  if not file_entry.reviewed and modified_buffer(context, file) then
    return nil, "save the buffer before marking it reviewed"
  end

  if file_entry.reviewed then
    file_entry.reviewed = false
    file_entry.invalidated = false
  else
    file_entry.reviewed = true
    file_entry.invalidated = false
    file_entry.fingerprint = change.fingerprint
  end
  if not save(context) then
    return nil, "could not persist reviewed state"
  end
  return {
    context = context,
    file = file,
    status = file_entry.reviewed and "reviewed" or "pending",
  }
end

local function buffer_lines(context, file, buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  local absolute = util.absolute(context.root, file)
  local loaded = vim.fn.bufnr(absolute)
  if loaded > 0 and vim.api.nvim_buf_is_loaded(loaded) then
    return vim.api.nvim_buf_get_lines(loaded, 0, -1, false)
  end
  return util.split_lines(util.read_file(absolute) or "")
end

---@param config table
---@param opts table
---@return table?, string?, table?
function M.create_comment(config, opts)
  local seed = opts.context
  local context, err = M.resolve(config, {
    root = seed and seed.root or opts.root,
    base = seed and seed.base or opts.base,
    buf = opts.buf,
  })
  if not context then
    return nil, err
  end

  local file = current_file(context, opts)
  if not file then
    return nil, "could not determine the file for this comment"
  end
  if not context.by_file[file] then
    return nil, "comments can only be added to files in the active review"
  end
  if type(opts.text) ~= "string" or not opts.text:match("%S") then
    return nil, "comments cannot be empty"
  end

  local start_line = opts.start_line
  local end_line = opts.end_line
  local anchor
  if start_line or end_line then
    if opts.binary or (opts.buf and vim.b[opts.buf].agentic_flow_binary) then
      return nil, "binary files only support file-level comments"
    end
    local lines = buffer_lines(context, file, opts.buf)
    start_line = math.max(1, math.min(start_line or end_line or 1, #lines))
    end_line = math.max(1, math.min(end_line or start_line, #lines))
    if end_line < start_line then
      start_line, end_line = end_line, start_line
    end
    anchor = {
      lines = vim.list_slice(lines, start_line, end_line),
      before = start_line > 1 and lines[start_line - 1] or nil,
      after = end_line < #lines and lines[end_line + 1] or nil,
    }
  end

  local id = ("%d-%06d"):format(os.time(), context.session.next_comment_id)
  context.session.next_comment_id = context.session.next_comment_id + 1
  local comment = {
    id = id,
    path = file,
    start_line = start_line,
    end_line = end_line,
    text = opts.text,
    anchor = anchor,
    stale = false,
    created_at = os.time(),
    updated_at = os.time(),
  }
  local file_entry = entry(context.session, file)
  file_entry.comments[#file_entry.comments + 1] = comment
  if not save(context) then
    return nil, "could not persist comment"
  end
  return comment, nil, context
end

local function find_comment(context, id)
  for file, file_entry in pairs(context.session.files) do
    for index, comment in ipairs(file_entry.comments or {}) do
      if tostring(comment.id) == tostring(id) then
        return comment, file_entry, index, file
      end
    end
  end
end

---@param config table
---@param opts table
---@return table?, string?, table?
function M.update_comment(config, opts)
  local seed = opts.context
  local context, err = M.resolve(config, {
    root = seed and seed.root or opts.root,
    base = seed and seed.base or opts.base,
  })
  if not context then
    return nil, err
  end
  local comment = find_comment(context, opts.id)
  if not comment then
    return nil, "comment not found"
  end
  if type(opts.text) ~= "string" or not opts.text:match("%S") then
    return nil, "comments cannot be empty"
  end
  comment.text = opts.text
  comment.updated_at = os.time()
  if not save(context) then
    return nil, "could not persist comment"
  end
  return comment, nil, context
end

---@param config table
---@param opts table
---@return boolean, string?
function M.delete_comment(config, opts)
  local seed = opts.context
  local context, err = M.resolve(config, {
    root = seed and seed.root or opts.root,
    base = seed and seed.base or opts.base,
  })
  if not context then
    return false, err
  end
  local _, file_entry, index = find_comment(context, opts.id)
  if not file_entry then
    return false, "comment not found"
  end
  table.remove(file_entry.comments, index)
  return save(context)
end

---@param config table
---@param opts? table
---@return boolean, string?
function M.clear_comments(config, opts)
  opts = opts or {}
  local seed = opts.context
  local context, err = M.resolve(config, {
    root = seed and seed.root or opts.root,
    base = seed and seed.base or opts.base,
  })
  if not context then
    return false, err
  end
  for _, file_entry in pairs(context.session.files) do
    file_entry.comments = {}
  end
  return save(context)
end

---@param context table
---@return table[]
function M.comments(context)
  local comments = {}
  for file, file_entry in pairs(context.session.files) do
    for _, stored in ipairs(file_entry.comments or {}) do
      local comment = vim.deepcopy(stored)
      comment.path = file
      comment.orphan = context.by_file[file] == nil
      comments[#comments + 1] = comment
    end
  end
  table.sort(comments, function(left, right)
    if left.path ~= right.path then
      return left.path < right.path
    end
    if (left.start_line == nil) ~= (right.start_line == nil) then
      return left.start_line == nil
    end
    if left.start_line ~= right.start_line then
      return (left.start_line or 0) < (right.start_line or 0)
    end
    if left.end_line ~= right.end_line then
      return (left.end_line or 0) < (right.end_line or 0)
    end
    return tostring(left.id) < tostring(right.id)
  end)
  return comments
end

local function comment_prefix(comment)
  if not comment.start_line then
    return comment.path
  end
  if comment.start_line == comment.end_line then
    return ("%s:%d"):format(comment.path, comment.start_line)
  end
  return ("%s:%d-%d"):format(comment.path, comment.start_line, comment.end_line)
end

---@param context table
---@return string, number
function M.render_comments(context)
  local output = {}
  local comments = M.comments(context)
  for _, comment in ipairs(comments) do
    output[#output + 1] = "@" .. comment_prefix(comment) .. " : " .. comment.text
  end
  return table.concat(output, "\n\n"), #comments
end

---@param config table
---@param opts? table
---@return string?, string?, number?
function M.copy_comments(config, opts)
  opts = opts or {}
  local seed = opts.context
  local context, err = M.resolve(config, {
    root = seed and seed.root or opts.root,
    base = seed and seed.base or opts.base,
  })
  if not context then
    return nil, err
  end
  local output, count = M.render_comments(context)
  if count == 0 then
    return nil, "there are no comments to copy"
  end
  vim.fn.setreg(opts.register or config.clipboard, output)
  return output, nil, count
end

local function block_matches(lines, start_line, anchor_lines)
  if start_line < 1 or start_line + #anchor_lines - 1 > #lines then
    return false
  end
  for offset, expected in ipairs(anchor_lines) do
    if lines[start_line + offset - 1] ~= expected then
      return false
    end
  end
  return true
end

---@param context table
---@param file string
---@param lines string[]
---@return boolean
function M.relocate_comments(context, file, lines)
  local file_entry = context.session.files[file]
  if not file_entry then
    return false
  end

  local changed = false
  for _, comment in ipairs(file_entry.comments or {}) do
    if comment.start_line and comment.anchor and #(comment.anchor.lines or {}) > 0 then
      local anchor_lines = comment.anchor.lines
      local resolved
      if block_matches(lines, comment.start_line, anchor_lines) then
        resolved = comment.start_line
      else
        local matches = {}
        for line = 1, math.max(0, #lines - #anchor_lines + 1) do
          if block_matches(lines, line, anchor_lines) then
            matches[#matches + 1] = line
          end
        end
        if #matches == 1 then
          resolved = matches[1]
        elseif #matches > 1 then
          local contextual = {}
          for _, line in ipairs(matches) do
            local before_matches = comment.anchor.before == nil
              or lines[line - 1] == comment.anchor.before
            local after_line = line + #anchor_lines
            local after_matches = comment.anchor.after == nil
              or lines[after_line] == comment.anchor.after
            if before_matches and after_matches then
              contextual[#contextual + 1] = line
            end
          end
          if #contextual == 1 then
            resolved = contextual[1]
          end
        end
      end

      local was_stale = comment.stale == true
      if resolved then
        local new_end = resolved + #anchor_lines - 1
        if comment.start_line ~= resolved or comment.end_line ~= new_end or was_stale then
          comment.start_line = resolved
          comment.end_line = new_end
          comment.stale = false
          changed = true
        end
      elseif not was_stale then
        comment.stale = true
        changed = true
      end
    end
  end
  if changed then
    save(context)
  end
  return changed
end

local function find_review_buffer(context, file)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_valid(buf)
      and vim.b[buf].agentic_flow_root == context.root
      and vim.b[buf].agentic_flow_path == file
    then
      return buf
    end
  end
end

local function deleted_buffer(context, change)
  local existing = find_review_buffer(context, change.file)
  if existing then
    return existing
  end

  local contents, err =
    git.file_at(context.root, context.merge_base, change.old_file or change.file)
  if not contents then
    return nil, err
  end
  local binary = contents:find("\0", 1, true) ~= nil
  local lines = binary and { ("Binary file: %s"):format(change.file) } or util.split_lines(contents)
  if #lines == 0 then
    lines = { "" }
  end

  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(
    buf,
    ("agentic-flow://deleted/%s/%s"):format(vim.fn.sha256(context.root):sub(1, 12), change.file)
  )
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].filetype = vim.filetype.match({ filename = change.file }) or ""
  vim.b[buf].agentic_flow_binary = binary
  return buf
end

---@param config table
---@param context table
---@param change table
---@param line? number
---@return number?, string?
function M.open_change(config, context, change, line)
  local buf
  if change.status == "D" or not vim.uv.fs_stat(util.absolute(context.root, change.file)) then
    local err
    buf, err = deleted_buffer(context, change)
    if not buf then
      return nil, err
    end
  else
    local absolute = util.absolute(context.root, change.file)
    buf = vim.fn.bufadd(absolute)
    vim.fn.bufload(buf)
    vim.b[buf].agentic_flow_binary = change.binary or false
  end

  vim.api.nvim_win_set_buf(0, buf)
  vim.b[buf].agentic_flow_root = context.root
  vim.b[buf].agentic_flow_base = context.base
  vim.b[buf].agentic_flow_path = change.file
  require("agentic-flow.ui").attach(config, context, change.file, buf)

  local target = math.max(1, math.min(line or change.line or 1, vim.api.nvim_buf_line_count(buf)))
  vim.api.nvim_win_set_cursor(0, { target, 0 })
  return buf
end

---@param config table
---@param context table
---@param comment table
---@return number?, string?
function M.open_comment(config, context, comment)
  local change = context.by_file[comment.path]
  if not change then
    local absolute = util.absolute(context.root, comment.path)
    change = {
      file = comment.path,
      status = vim.uv.fs_stat(absolute) and "M" or "D",
      line = comment.start_line or 1,
      binary = false,
    }
  end
  return M.open_change(config, context, change, comment.start_line or 1)
end

return M
