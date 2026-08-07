local git = require("agentic-flow.git")
local pipeline = require("agentic-flow.pipeline")
local review = require("agentic-flow.review")
local signs = require("agentic-flow.signs")
local util = require("agentic-flow.util")

local M = {}

---@class AgenticFlow.DiffPosition
---@field file string
---@field line integer
---@field start_line? integer
---@field end_line? integer
---@field hunk? AgenticFlow.Hunk
---@field side "before"|"after"

---@type { open: boolean, key: string?, context: AgenticFlow.Context?, config: AgenticFlow.Config?, file: string?, before_win: integer?, after_win: integer?, before_buf: integer?, after_buf: integer?, after_scratch: boolean, generation: integer }
local state = {
  open = false,
  key = nil,
  context = nil,
  config = nil,
  file = nil,
  before_win = nil,
  after_win = nil,
  before_buf = nil,
  after_buf = nil,
  after_scratch = false,
  generation = 0,
}

---@param win? integer
---@return boolean
local function valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

---@param buf? integer
---@return boolean
local function valid_buf(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

---@param err? string
local function notify_error(err)
  util.notify(err or "Unknown diff error", vim.log.levels.ERROR)
end

---@param win? integer
local function disable_diff(win)
  if valid_win(win) then
    pcall(vim.api.nvim_win_call, win, function()
      vim.cmd.diffoff()
    end)
  end
end

---@param buf? integer
local function wipe(buf)
  if valid_buf(buf) then
    ---@cast buf -nil
    signs.detach(buf)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

---@param name string
---@param contents string
---@param file string
---@return integer buf
local function scratch_buffer(name, contents, file)
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  local lines
  if contents:find("\0", 1, true) then
    lines = { "Binary file" }
  else
    lines = util.split_lines(contents)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  local filetype = vim.filetype.match({ filename = file })
  if filetype then
    vim.bo[buf].filetype = filetype
  end
  return buf
end

---@param buf integer
---@param context AgenticFlow.Context
---@param file string
---@param side "before"|"after"
local function set_buffer_context(buf, context, file, side)
  vim.b[buf].agentic_flow_root = context.root
  vim.b[buf].agentic_flow_branch = context.branch
  vim.b[buf].agentic_flow_base = context.base
  vim.b[buf].agentic_flow_path = file
  vim.b[buf].agentic_flow_side = side
end

---@param context AgenticFlow.Context
---@param change AgenticFlow.Change
---@return integer buf
---@return boolean scratch
local function worktree_buffer(context, change)
  if change.status == "D" then
    return scratch_buffer("agentic-flow://after/" .. change.file, "", change.file), true
  end
  local buf = vim.fn.bufadd(util.absolute(context.root, change.file))
  vim.fn.bufload(buf)
  return buf, false
end

---@return integer? win
local function editing_window()
  local current = vim.api.nvim_get_current_win()
  if vim.bo[vim.api.nvim_win_get_buf(current)].filetype ~= "agentic-flow-tree" then
    return current
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype ~= "agentic-flow-tree" then
      return win
    end
  end
end

---@return true? ok
---@return string? err
local function prepare_windows()
  local after_win = editing_window()
  if not after_win then
    return nil, "could not find the main editing window"
  end
  vim.api.nvim_set_current_win(after_win)
  vim.cmd("leftabove vnew")
  state.before_win = vim.api.nvim_get_current_win()
  state.after_win = after_win
  state.before_buf = vim.api.nvim_get_current_buf()
  return true
end

---@param context AgenticFlow.Context
---@param change AgenticFlow.Change
---@param line integer
---@return integer before_line
---@return integer after_line
local function cursor_lines(context, change, line)
  if change.status == "D" then
    return line, 1
  end
  local hunk = review.hunk_at_line(context, change.file, line)
  return hunk and hunk.old_anchor or line, line
end

---@param win integer
---@param line integer
local function set_cursor(win, line)
  line = math.max(
    1,
    math.min(line, math.max(1, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))))
  )
  vim.api.nvim_win_set_cursor(win, { line, 0 })
end

---@param context AgenticFlow.Context
---@param change AgenticFlow.Change
---@param contents string
---@param line integer
---@param generation integer
---@param callback? fun(ok: boolean?, err: string?)
local function apply_buffers(context, change, contents, line, generation, callback)
  if
    generation ~= state.generation
    or not state.open
    or not valid_win(state.before_win)
    or not valid_win(state.after_win)
  then
    return
  end

  local focused_side = vim.api.nvim_get_current_win() == state.before_win and "before" or "after"
  local old_before = state.before_buf
  local old_after = state.after_scratch and state.after_buf or nil
  disable_diff(state.before_win)
  disable_diff(state.after_win)

  local before = scratch_buffer(
    ("agentic-flow://before/%d/%s"):format(generation, change.file),
    contents,
    change.old_file or change.file
  )
  local after, after_scratch = worktree_buffer(context, change)
  vim.api.nvim_win_set_buf(state.before_win, before)
  vim.api.nvim_win_set_buf(state.after_win, after)
  state.before_buf = before
  state.after_buf = after
  state.after_scratch = after_scratch
  state.context = context
  state.key = context.key
  state.file = change.file

  set_buffer_context(before, context, change.file, "before")
  set_buffer_context(after, context, change.file, "after")
  signs.attach(state.config, context, change.file, before, "before")
  if change.status ~= "D" then
    signs.attach(state.config, context, change.file, after, "after")
  end

  vim.api.nvim_win_call(state.before_win, function()
    vim.cmd.diffthis()
  end)
  vim.api.nvim_win_call(state.after_win, function()
    vim.cmd.diffthis()
  end)
  local before_line, after_line = cursor_lines(context, change, line)
  set_cursor(state.before_win, before_line)
  set_cursor(state.after_win, after_line)
  -- Both windows passed valid_win at the top of this function.
  ---@diagnostic disable-next-line: param-type-mismatch
  vim.api.nvim_set_current_win(focused_side == "before" and state.before_win or state.after_win)

  if old_before ~= before then
    wipe(old_before)
  end
  if old_after and old_after ~= after then
    wipe(old_after)
  end
  if callback then
    callback(true)
  end
end

---@param context AgenticFlow.Context
---@param change AgenticFlow.Change
---@param line integer
---@param generation integer
---@param callback? fun(ok: boolean?, err: string?)
local function load_before(context, change, line, generation, callback)
  if change.status == "A" or change.status == "?" then
    apply_buffers(context, change, "", line, generation, callback)
    return
  end
  git.file_at(
    context.root,
    context.merge_base,
    change.old_file or change.file,
    function(contents, err)
      vim.schedule(function()
        if generation ~= state.generation then
          return
        end
        if not contents then
          if callback then
            callback(nil, err)
          end
          return notify_error(err)
        end
        apply_buffers(context, change, contents, line, generation, callback)
      end)
    end
  )
end

---Retarget an open diff view without replacing either window.
---@param config AgenticFlow.Config
---@param context AgenticFlow.Context
---@param file string
---@param line? integer
---@param callback? fun(ok: boolean?, err: string?)
---@return true? ok
---@return string? err
function M.retarget(config, context, file, line, callback)
  if not state.open then
    return M.open(config, context, file, line, callback)
  end
  local change = context.by_file[file]
  if not change then
    local err = "the file is not part of this review"
    if callback then
      callback(nil, err)
    end
    return nil, err
  end
  state.config = config
  state.generation = state.generation + 1
  local generation = state.generation
  load_before(context, change, line or change.line or 1, generation, callback)
  return true
end

---Open a before | after diff in the current editing area.
---@param config AgenticFlow.Config
---@param context AgenticFlow.Context
---@param file string
---@param line? integer
---@param callback? fun(ok: boolean?, err: string?)
---@return true? ok
---@return string? err
function M.open(config, context, file, line, callback)
  if state.open then
    return M.retarget(config, context, file, line, callback)
  end
  state.config = config
  state.key = context.key
  state.context = context
  local ok, err = prepare_windows()
  if not ok then
    if callback then
      callback(nil, err)
    end
    return nil, err
  end
  state.open = true
  return M.retarget(config, context, file, line, callback)
end

---@return boolean
function M.is_open()
  return state.open and valid_win(state.before_win) and valid_win(state.after_win)
end

---@return integer?
function M.before_win()
  return valid_win(state.before_win) and state.before_win or nil
end

---@return integer?
function M.after_win()
  return valid_win(state.after_win) and state.after_win or nil
end

---@return integer?
function M.before_buf()
  return valid_buf(state.before_buf) and state.before_buf or nil
end

---@return integer?
function M.after_buf()
  return valid_buf(state.after_buf) and state.after_buf or nil
end

---Resolve a cursor position to the review's new-side coordinate. Before-side
---mapping is intentionally experimental: the containing old-side hunk maps
---to its new-side cursor range (or deletion anchor).
---@param buf? integer
---@param line? integer
---@return AgenticFlow.DiffPosition?
function M.position(buf, line)
  if not M.is_open() then
    return nil
  end
  buf = buf or vim.api.nvim_get_current_buf()
  line = line or vim.api.nvim_win_get_cursor(0)[1]
  local context = pipeline.get(state.key)
  if not context then
    return nil
  end
  if buf == state.before_buf then
    local hunk = review.hunk_at_old_line(context, state.file, line)
    if not hunk then
      return { file = state.file, line = line, side = "before" }
    end
    return {
      file = state.file,
      line = hunk.anchor,
      start_line = hunk.new_cursor_start,
      end_line = hunk.new_cursor_end,
      hunk = hunk,
      side = "before",
    }
  end
  return { file = state.file, line = line, start_line = line, end_line = line, side = "after" }
end

---Toggle the hunk under the cursor on either side of the diff.
---@return { file: string, hunk: AgenticFlow.Hunk, status: "reviewed"|"pending", reviewed: integer, total: integer }? result
---@return string? err
function M.toggle_hunk()
  local position = M.position()
  local context = pipeline.get(state.key)
  if not position or not context then
    return nil
  end
  local hunk = position.hunk or review.hunk_at_line(context, position.file, position.line)
  if not hunk then
    util.notify("The cursor is not on a review hunk", vim.log.levels.WARN)
    return nil
  end
  return pipeline.toggle_hunk(state.key, position.file, hunk.fingerprint)
end

---Navigate to an unreviewed hunk while preserving diff mode and both windows.
---@param direction "next"|"previous"
---@return { file_index: integer, file: string, change: AgenticFlow.Change, hunk: AgenticFlow.Hunk, line: integer }?
function M.navigate(direction)
  if not M.is_open() then
    return nil
  end
  local context = pipeline.get(state.key)
  local position = M.position()
  if not context or not position then
    return nil
  end
  local target, err = review.navigation_target(context, position.file, position.line, direction)
  if not target then
    ---@cast err string
    util.notify(err, vim.log.levels.WARN)
    return nil
  end
  if target.file ~= state.file then
    M.retarget(state.config, context, target.file, target.line)
    return target
  end
  local win = position.side == "before" and state.before_win or state.after_win
  local line = position.side == "before" and target.hunk.old_anchor or target.line
  ---@cast win -nil
  set_cursor(win, line)
  return target
end

---Close diff mode, wipe the before scratch, and retain the after window.
function M.close()
  if not state.open then
    return
  end
  state.generation = state.generation + 1
  local before_win = state.before_win
  local after_win = state.after_win
  local before_buf = state.before_buf
  disable_diff(before_win)
  disable_diff(after_win)
  if valid_win(after_win) then
    ---@cast after_win -nil
    vim.api.nvim_set_current_win(after_win)
  end
  if valid_win(before_win) then
    ---@cast before_win -nil
    vim.api.nvim_win_close(before_win, true)
  end
  wipe(before_buf)
  state.open = false
  state.key = nil
  state.context = nil
  state.file = nil
  state.before_win = nil
  state.before_buf = nil
  state.after_win = nil
  state.after_buf = nil
  state.after_scratch = false
end

---Toggle diff mode for an explicit review file.
---@param config AgenticFlow.Config
---@param context AgenticFlow.Context
---@param file string
---@param line? integer
---@return boolean
function M.toggle(config, context, file, line)
  if M.is_open() then
    M.close()
    return false
  end
  M.open(config, context, file, line)
  return true
end

---@param config AgenticFlow.Config
function M.setup(config)
  state.config = config
  local group = vim.api.nvim_create_augroup("AgenticFlowDiff", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AgenticFlowContextRefreshed",
    callback = function(args)
      if state.open and args.data and args.data.key == state.key then
        state.context = pipeline.get(state.key)
      end
    end,
  })
  -- A checkout re-keys the context under the open diff view. Following the key
  -- is what keeps every command issued here talking to the branch on disk; the
  -- before side is reloaded too, since its merge-base contents just moved. A
  -- file that left the diff keeps its windows and simply stops being diffed
  -- against anything new.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AgenticFlowContextMigrated",
    callback = function(args)
      if not state.open or not args.data or args.data.from ~= state.key then
        return
      end
      state.key = args.data.to
      local context = pipeline.get(state.key)
      if not context then
        return
      end
      state.context = context
      if state.file and context.by_file[state.file] then
        M.retarget(state.config, context, state.file)
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AgenticFlowReviewClosed",
    callback = function(args)
      if state.open and args.data and args.data.key == state.key then
        M.close()
      end
    end,
  })
end

return M
