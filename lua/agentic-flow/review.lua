--- Pure review domain. Every function operates on an explicit context
--- (built by the pipeline) plus explicit inputs — no window, buffer, or git
--- calls — so the whole layer is headless-testable.
---
--- A context is `{ root, branch, base, merge_base, storage_dir, changes,
--- by_file, session }`.
local state = require("agentic-flow.state")
local util = require("agentic-flow.util")

local M = {}

---@param context AgenticFlow.Context
---@return boolean
local function save(context)
  local ok, err = state.save(context.storage_dir, context.session)
  if not ok then
    util.notify("Could not save review state: " .. (err or "unknown error"), vim.log.levels.ERROR)
  end
  return ok
end

---@param session AgenticFlow.Session
---@param file string
---@return AgenticFlow.FileEntry
local function entry(session, file)
  session.files[file] = session.files[file] or { comments = {} }
  session.files[file].comments = session.files[file].comments or {}
  session.files[file].reviewed_hunks = type(session.files[file].reviewed_hunks) == "table"
      and session.files[file].reviewed_hunks
    or {}
  return session.files[file]
end

---@param change AgenticFlow.Change
---@return table<string, true>
local function hunk_lookup(change)
  local lookup = {}
  for _, hunk in ipairs(change.hunks or {}) do
    lookup[hunk.fingerprint] = true
  end
  return lookup
end

---@param file_entry AgenticFlow.FileEntry?
---@param change AgenticFlow.Change
---@return integer
local function reviewed_hunk_count(file_entry, change)
  local reviewed = 0
  local stored = file_entry and file_entry.reviewed_hunks or {}
  for _, hunk in ipairs(change.hunks or {}) do
    if stored[hunk.fingerprint] then
      reviewed = reviewed + 1
    end
  end
  return reviewed
end

---Reconcile one file's stored entry with its fresh change.
---
---File states (see CONTEXT.md): **pending** — no reviewed hunks and nothing
---was lost; **partial** — some hunks reviewed; **reviewed** — every hunk
---reviewed (or the file-level flag for non-textual changes); **invalidated**
---— previously reviewed work no longer applies: every reviewed hunk
---disappeared from the diff, a file-level fingerprint moved on, or the file
---left the diff entirely (handled by the caller).
---
---Because this only ever runs for a file that *is* in the diff, it is also
---where an **off-diff comment** loses that status: from here on the ground
---can move under it, so leaving the diff again would orphan it.
---@param file_entry AgenticFlow.FileEntry
---@param change AgenticFlow.Change
---@return boolean changed
local function sync_file(file_entry, change)
  local changed = false
  file_entry.comments = file_entry.comments or {}
  if type(file_entry.reviewed_hunks) ~= "table" then
    file_entry.reviewed_hunks = {}
    changed = true
  end
  for _, comment in ipairs(file_entry.comments) do
    if comment.off_diff then
      comment.off_diff = false
      changed = true
    end
  end

  if #(change.hunks or {}) > 0 then
    local current_hunks = hunk_lookup(change)
    local removed_reviewed_hunk = false
    for fingerprint in pairs(file_entry.reviewed_hunks) do
      if not current_hunks[fingerprint] then
        file_entry.reviewed_hunks[fingerprint] = nil
        removed_reviewed_hunk = true
        changed = true
      end
    end

    local was_reviewed = file_entry.reviewed == true
    local reviewed = reviewed_hunk_count(file_entry, change)
    local all_reviewed = reviewed == #change.hunks
    if
      reviewed == 0
      and (removed_reviewed_hunk or (was_reviewed and file_entry.fingerprint ~= change.fingerprint))
      and not all_reviewed
      and not file_entry.invalidated
    then
      file_entry.invalidated = true
      changed = true
    end
    if file_entry.reviewed ~= all_reviewed then
      file_entry.reviewed = all_reviewed
      changed = true
    end
    if all_reviewed then
      if file_entry.fingerprint ~= change.fingerprint then
        file_entry.fingerprint = change.fingerprint
        changed = true
      end
      if file_entry.invalidated then
        file_entry.invalidated = false
        changed = true
      end
    end
  else
    -- Non-textual change (binary, pure rename): only file-level review
    -- exists; a content change invalidates it.
    local had_reviewed_hunks = next(file_entry.reviewed_hunks) ~= nil
    if had_reviewed_hunks then
      file_entry.reviewed_hunks = {}
      changed = true
    end
    if
      had_reviewed_hunks
      or (file_entry.reviewed and file_entry.fingerprint ~= change.fingerprint)
    then
      file_entry.reviewed = false
      file_entry.invalidated = true
      changed = true
    end
  end
  return changed
end

---Reconcile the whole session with the fresh change listing: follow renames,
---run the per-file transition, and invalidate entries whose file left the
---diff. Persists when anything moved.
---
---An entry holding only **off-diff comments** carries no review state, so
---the departed-file pass below never touches it — a deliberate note is not
---retroactively turned into an **orphan comment**.
---@param context AgenticFlow.Context
---@return boolean changed
function M.sync_session(context)
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
    if file_entry then
      changed = sync_file(file_entry, change) or changed
    end
  end

  for file, file_entry in pairs(context.session.files) do
    if not active[file] then
      local had_reviewed_hunks = type(file_entry.reviewed_hunks) == "table"
        and next(file_entry.reviewed_hunks) ~= nil
      if file_entry.reviewed or had_reviewed_hunks then
        file_entry.reviewed = false
        file_entry.reviewed_hunks = {}
        file_entry.invalidated = true
        changed = true
      end
    end
  end

  if changed then
    save(context)
  end
  return changed
end

---@param context AgenticFlow.Context
---@param file string
---@return "reviewed"|"partial"|"invalidated"|"pending" status, integer comments, integer reviewed, integer total
function M.file_status(context, file)
  local change = context.by_file[file]
  local file_entry = context.session.files[file]
  local comments = file_entry and #(file_entry.comments or {}) or 0
  if change and #(change.hunks or {}) > 0 then
    local reviewed = reviewed_hunk_count(file_entry, change)
    local total = #change.hunks
    if reviewed == total then
      return "reviewed", comments, reviewed, total
    end
    if reviewed > 0 then
      return "partial", comments, reviewed, total
    end
    if file_entry and file_entry.invalidated then
      return "invalidated", comments, reviewed, total
    end
    return "pending", comments, reviewed, total
  end
  if file_entry and file_entry.reviewed then
    return "reviewed", comments, 0, 0
  end
  if file_entry and file_entry.invalidated then
    return "invalidated", comments, 0, 0
  end
  return "pending", comments, 0, 0
end

---Every file of the review beneath `directory`, at any depth. Paths are not
---compacted, so a directory node names one path component and the prefix walk
---below is what makes marking reach the whole subtree.
---@param context AgenticFlow.Context
---@param directory string
---@return string[]
function M.directory_files(context, directory)
  local prefix = directory .. "/"
  local files = {}
  for _, change in ipairs(context.changes) do
    if vim.startswith(change.file, prefix) then
      files[#files + 1] = change.file
    end
  end
  return files
end

---A directory's **derived status**: computed from its descendants on every
---call and never stored. Nothing being stored is what preserves **Freshness** —
---a file that appears inside an already-marked directory arrives pending
---instead of being swallowed by a directory-level flag.
---
---`invalidated` outranks every other state and, because every ancestor derives
---from the same descendants, it propagates to the root. The counts come back
---alongside it: the glyph carries the alarm, the badge carries the progress.
---@param context AgenticFlow.Context
---@param directory string
---@return "reviewed"|"partial"|"invalidated"|"pending" status, integer reviewed, integer total
function M.directory_status(context, directory)
  local files = M.directory_files(context, directory)
  local reviewed, invalidated, started = 0, false, false
  for _, file in ipairs(files) do
    local status = M.file_status(context, file)
    if status == "reviewed" then
      reviewed = reviewed + 1
      started = true
    elseif status == "invalidated" then
      invalidated = true
    elseif status == "partial" then
      started = true
    end
  end
  if invalidated then
    return "invalidated", reviewed, #files
  end
  if #files > 0 and reviewed == #files then
    return "reviewed", reviewed, #files
  end
  if started then
    return "partial", reviewed, #files
  end
  return "pending", reviewed, #files
end

---@param context AgenticFlow.Context
---@param file string
---@return integer reviewed, integer total
function M.hunk_progress(context, file)
  local change = context.by_file[file]
  if not change then
    return 0, 0
  end
  return reviewed_hunk_count(context.session.files[file], change), #(change.hunks or {})
end

---@param context AgenticFlow.Context
---@param file string
---@param hunk AgenticFlow.Hunk
---@return boolean
function M.hunk_reviewed(context, file, hunk)
  local file_entry = context.session.files[file]
  return file_entry ~= nil
    and type(file_entry.reviewed_hunks) == "table"
    and file_entry.reviewed_hunks[hunk.fingerprint] ~= nil
end

---@param context AgenticFlow.Context
---@return integer reviewed, integer total
function M.progress(context)
  local reviewed = 0
  for _, change in ipairs(context.changes) do
    if M.file_status(context, change.file) == "reviewed" then
      reviewed = reviewed + 1
    end
  end
  return reviewed, #context.changes
end

---@param change AgenticFlow.Change
---@param hunk AgenticFlow.Hunk
---@return integer start_line, integer end_line
local function hunk_bounds(change, hunk)
  if change.status == "D" then
    return hunk.old_cursor_start, hunk.old_cursor_end
  end
  return hunk.new_cursor_start, hunk.new_cursor_end
end

---@param change AgenticFlow.Change
---@param hunk AgenticFlow.Hunk
---@return integer
local function hunk_anchor(change, hunk)
  return change.status == "D" and hunk.old_anchor or hunk.anchor
end

---Resolve the hunk containing `line` on the current side (old side for
---deleted files, whose buffers show the merge-base contents).
---@param context AgenticFlow.Context
---@param file string
---@param line integer
---@return AgenticFlow.Hunk?
function M.hunk_at_line(context, file, line)
  local change = context.by_file[file]
  if not change then
    return nil
  end
  for _, hunk in ipairs(change.hunks or {}) do
    local start_line, end_line = hunk_bounds(change, hunk)
    if line >= start_line and line <= end_line then
      return hunk
    end
  end
end

---Resolve the hunk containing an old-side `line` — the diff view's before
---side maps its cursor through this.
---@param context AgenticFlow.Context
---@param file string
---@param line integer
---@return AgenticFlow.Hunk?
function M.hunk_at_old_line(context, file, line)
  local change = context.by_file[file]
  if not change then
    return nil
  end
  for _, hunk in ipairs(change.hunks or {}) do
    if line >= hunk.old_cursor_start and line <= hunk.old_cursor_end then
      return hunk
    end
  end
end

---@param context AgenticFlow.Context
---@param file string
---@param change AgenticFlow.Change
---@return integer reviewed
local function update_file_review_state(context, file, change)
  local file_entry = entry(context.session, file)
  local reviewed = reviewed_hunk_count(file_entry, change)
  file_entry.reviewed = #change.hunks > 0 and reviewed == #change.hunks
  file_entry.invalidated = false
  file_entry.fingerprint = file_entry.reviewed and change.fingerprint or nil
  return reviewed
end

---Toggle one hunk, keyed by fingerprint. Records `reviewed_at` on review.
---@param context AgenticFlow.Context
---@param file string
---@param fingerprint string
---@return { file: string, hunk: AgenticFlow.Hunk, status: "reviewed"|"pending", reviewed: integer, total: integer }?, string?
function M.toggle_hunk(context, file, fingerprint)
  local change = context.by_file[file]
  if not change then
    return nil, "the file is not part of this review"
  end
  if #(change.hunks or {}) == 0 then
    return nil, "the file has no textual review hunks"
  end

  local hunk
  for _, candidate in ipairs(change.hunks) do
    if candidate.fingerprint == fingerprint then
      hunk = candidate
      break
    end
  end
  if not hunk then
    return nil, "this hunk is no longer part of this review (stale fingerprint)"
  end

  local file_entry = entry(context.session, file)
  local was_reviewed = file_entry.reviewed_hunks[fingerprint] ~= nil
  if was_reviewed then
    file_entry.reviewed_hunks[fingerprint] = nil
  else
    file_entry.reviewed_hunks[fingerprint] = { reviewed_at = os.time() }
  end
  local reviewed = update_file_review_state(context, file, change)
  if not save(context) then
    return nil, "could not persist hunk review state"
  end
  return {
    file = file,
    hunk = hunk,
    status = was_reviewed and "pending" or "reviewed",
    reviewed = reviewed,
    total = #change.hunks,
  }
end

---Drive one file to a whole-file reviewed state without persisting: review
---every hunk (or the file-level flag for non-textual changes), or reset
---everything back to pending. Callers own the `save`, so a fan-out across a
---directory costs one write rather than one per file.
---@param context AgenticFlow.Context
---@param file string
---@param change AgenticFlow.Change
---@param reviewed boolean
local function set_file_reviewed(context, file, change, reviewed)
  local file_entry = entry(context.session, file)
  file_entry.invalidated = false
  file_entry.reviewed_hunks = {}
  file_entry.reviewed = reviewed
  file_entry.fingerprint = reviewed and change.fingerprint or nil
  if reviewed then
    local reviewed_at = os.time()
    for _, hunk in ipairs(change.hunks or {}) do
      file_entry.reviewed_hunks[hunk.fingerprint] = { reviewed_at = reviewed_at }
    end
  end
end

---Toggle a whole file: review every hunk (or the file-level flag for
---non-textual changes), or reset everything back to pending.
---@param context AgenticFlow.Context
---@param file string
---@return { file: string, status: "reviewed"|"pending" }?, string?
function M.toggle_file(context, file)
  local change = context.by_file[file]
  if not change then
    return nil, "the file is not part of this review"
  end

  local reviewed = M.file_status(context, file) ~= "reviewed"
  set_file_reviewed(context, file, change, reviewed)
  if not save(context) then
    return nil, "could not persist reviewed state"
  end
  return { file = file, status = reviewed and "reviewed" or "pending" }
end

---Toggle a **directory**: exactly pressing `r` on every file beneath it, at
---any depth. A directory that is not fully reviewed is marked, a fully
---reviewed one is unmarked — never file-by-file inversion, which would turn a
---partial directory into its photographic negative.
---
---The directory itself holds no review state; only the files move, and one
---`save` covers all of them.
---@param context AgenticFlow.Context
---@param directory string
---@return { directory: string, status: "reviewed"|"pending", files: string[] }?, string?
function M.toggle_directory(context, directory)
  local files = M.directory_files(context, directory)
  if #files == 0 then
    return nil, "the directory has no files in this review"
  end

  local reviewed = M.directory_status(context, directory) ~= "reviewed"
  for _, file in ipairs(files) do
    set_file_reviewed(context, file, context.by_file[file], reviewed)
  end
  if not save(context) then
    return nil, "could not persist reviewed state"
  end
  return {
    directory = directory,
    status = reviewed and "reviewed" or "pending",
    files = files,
  }
end

---@param context AgenticFlow.Context
---@return { file_index: integer, file: string, change: AgenticFlow.Change, hunk: AgenticFlow.Hunk, line: integer }[]
local function unreviewed_hunks(context)
  local items = {}
  for file_index, change in ipairs(context.changes) do
    for _, hunk in ipairs(change.hunks or {}) do
      if not M.hunk_reviewed(context, change.file, hunk) then
        items[#items + 1] = {
          file_index = file_index,
          file = change.file,
          change = change,
          hunk = hunk,
          line = hunk_anchor(change, hunk),
        }
      end
    end
  end
  return items
end

---@param context AgenticFlow.Context
---@param file string
---@return integer?
local function current_file_index(context, file)
  for index, change in ipairs(context.changes) do
    if change.file == file then
      return index
    end
  end
end

---Pick the next/previous unreviewed hunk relative to `(file, line)`,
---wrapping across files. Pure data — the caller opens buffers.
---@param context AgenticFlow.Context
---@param file? string
---@param line integer
---@param direction "next"|"previous"
---@return { file_index: integer, file: string, change: AgenticFlow.Change, hunk: AgenticFlow.Hunk, line: integer }?, string?
function M.navigation_target(context, file, line, direction)
  local items = unreviewed_hunks(context)
  if #items == 0 then
    return nil, "there are no unreviewed hunks"
  end
  local file_index = file and current_file_index(context, file) or nil
  if direction == "previous" then
    for index = #items, 1, -1 do
      local item = items[index]
      if
        not file_index
        or item.file_index < file_index
        or (item.file_index == file_index and item.line < line)
      then
        return item
      end
    end
    return items[#items]
  end
  for _, item in ipairs(items) do
    if
      not file_index
      or item.file_index > file_index
      or (item.file_index == file_index and item.line > line)
    then
      return item
    end
  end
  return items[1]
end

---@param root string
---@param file string
---@return boolean
local function exists(root, file)
  local stat = vim.uv.fs_stat(util.absolute(root, file))
  return stat ~= nil and stat.type == "file"
end

---@param context AgenticFlow.Context
---@param file string
---@param provided string[]?
---@return string[]
local function file_lines(context, file, provided)
  if provided then
    return provided
  end
  return util.split_lines(util.read_file(util.absolute(context.root, file)) or "")
end

---Create a file-level or ranged comment. Anchor context comes from
---`opts.lines` when given (live buffer contents), the on-disk file
---otherwise. Binary rejection follows the change data, never how a buffer
---was opened.
---
---Any file in the repository can hold a comment: annotating an unchanged
---caller of the thing you changed is a normal act, and the result is an
---**off-diff comment** — kept, and never flagged the way an **orphan
---comment** is. A path that is neither in the diff nor on disk is a mistake,
---not a deliberate note, so it is still refused.
---@param context AgenticFlow.Context
---@param opts { file: string, text: string, start_line?: integer, end_line?: integer, lines?: string[] }
---@return AgenticFlow.Comment?, string?
function M.create_comment(context, opts)
  local file = opts.file
  if type(file) ~= "string" or file == "" then
    return nil, "comments need a file"
  end
  local change = context.by_file[file]
  if not change and not exists(context.root, file) then
    return nil, "comments can only be added to files in the repository"
  end
  if type(opts.text) ~= "string" or not opts.text:match("%S") then
    return nil, "comments cannot be empty"
  end

  local start_line = opts.start_line
  local end_line = opts.end_line
  local anchor
  if start_line or end_line then
    if change and change.binary then
      return nil, "binary files only support file-level comments"
    end
    local lines = file_lines(context, file, opts.lines)
    start_line = math.max(1, math.min(start_line or end_line or 1, math.max(1, #lines)))
    end_line = math.max(1, math.min(end_line or start_line, math.max(1, #lines)))
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
    off_diff = change == nil,
    created_at = os.time(),
    updated_at = os.time(),
  }
  local file_entry = entry(context.session, file)
  file_entry.comments[#file_entry.comments + 1] = comment
  if not save(context) then
    return nil, "could not persist comment"
  end
  return comment
end

---@param context AgenticFlow.Context
---@param id string|number
---@return AgenticFlow.Comment? comment, AgenticFlow.FileEntry? file_entry, integer? index, string? file
local function find_comment(context, id)
  for file, file_entry in pairs(context.session.files) do
    for index, comment in ipairs(file_entry.comments or {}) do
      if tostring(comment.id) == tostring(id) then
        return comment, file_entry, index, file
      end
    end
  end
end

---@param context AgenticFlow.Context
---@param opts { id: string|number, text: string }
---@return AgenticFlow.Comment?, string?
function M.update_comment(context, opts)
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
  return comment
end

---@param context AgenticFlow.Context
---@param id string|number
---@return boolean, string?
function M.delete_comment(context, id)
  local _, file_entry, index = find_comment(context, id)
  if not file_entry then
    return false, "comment not found"
  end
  table.remove(file_entry.comments, index)
  return save(context)
end

---@param context AgenticFlow.Context
---@return boolean, string?
function M.clear_comments(context)
  for _, file_entry in pairs(context.session.files) do
    file_entry.comments = {}
  end
  return save(context)
end

---Every comment in the review, sorted in **tree order** → range, with orphan
---flags for files that left the diff. The export reads in the same order the
---sidebar does; a pasted prompt that disagreed with the tree would be the same
---defect in a different window.
---
---Being outside the diff is not enough to orphan a comment: an **off-diff
---comment** was placed on a file that was never in it, so nothing moved
---under it. Only a comment that *lost* its diff membership is flagged.
---@param context AgenticFlow.Context
---@return AgenticFlow.Comment[]
function M.comments(context)
  local comments = {}
  for file, file_entry in pairs(context.session.files) do
    for _, stored in ipairs(file_entry.comments or {}) do
      local comment = vim.deepcopy(stored)
      comment.path = file
      comment.off_diff = stored.off_diff == true
      comment.orphan = context.by_file[file] == nil and not comment.off_diff
      comments[#comments + 1] = comment
    end
  end
  local keys = {}
  for _, comment in ipairs(comments) do
    keys[comment.path] = keys[comment.path] or util.tree_key(comment.path)
  end
  table.sort(comments, function(left, right)
    if left.path ~= right.path then
      return keys[left.path] < keys[right.path]
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

---@param comment AgenticFlow.Comment
---@return string
local function comment_prefix(comment)
  if not comment.start_line then
    return comment.path
  end
  if comment.start_line == comment.end_line then
    return ("%s:%d"):format(comment.path, comment.start_line)
  end
  return ("%s:%d-%d"):format(comment.path, comment.start_line, comment.end_line)
end

---Render all comments in the stable `@path:range : text` format.
---@param context AgenticFlow.Context
---@return string, integer
function M.render_comments(context)
  local output = {}
  local comments = M.comments(context)
  for _, comment in ipairs(comments) do
    output[#output + 1] = "@" .. comment_prefix(comment) .. " : " .. comment.text
  end
  return table.concat(output, "\n\n"), #comments
end

---@param context AgenticFlow.Context
---@param register string
---@return string?, string?, integer?
function M.copy_comments(context, register)
  local output, count = M.render_comments(context)
  if count == 0 then
    return nil, "there are no comments to copy"
  end
  vim.fn.setreg(register, output)
  return output, nil, count
end

---@param lines string[]
---@param start_line integer
---@param anchor_lines string[]
---@return boolean
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

---Re-anchor `file`'s comments against fresh `lines`: exact position, then
---unique full-file match, then context disambiguation; otherwise the comment
---is flagged stale — never silently moved.
---@param context AgenticFlow.Context
---@param file string
---@param lines string[]
---@return boolean changed
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

return M
