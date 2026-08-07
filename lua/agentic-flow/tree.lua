--- Plain-buffer review sidebar. The tree is a projection of the pipeline
--- context it was opened for: review state stays in `review`, async work stays
--- in `pipeline`, and this module owns only rendering and window interaction.
local git = require("agentic-flow.git")
local pipeline = require("agentic-flow.pipeline")
local review = require("agentic-flow.review")
local signs = require("agentic-flow.signs")
local util = require("agentic-flow.util")

local M = {}

---@alias AgenticFlow.TreeStatus "pending"|"partial"|"invalidated"|"reviewed"

---@class AgenticFlow.TreeContainer
---@field directories table<string, AgenticFlow.TreeDirectory>
---@field files AgenticFlow.TreeFile[]

---@class AgenticFlow.TreeDirectory: AgenticFlow.TreeContainer
---@field name string
---@field path string

---@class AgenticFlow.TreeFile
---@field name string
---@field file string
---@field change? AgenticFlow.Change
---@field orphaned? boolean

---@alias AgenticFlow.TreeEntry { kind: "directory", name: string, value: AgenticFlow.TreeDirectory }|{ kind: "file", name: string, value: AgenticFlow.TreeFile }

---@class AgenticFlow.TreeNode
---@field kind "loading"|"directory"|"file"
---@field path? string
---@field file? string
---@field change? AgenticFlow.Change
---@field status? AgenticFlow.TreeStatus
---@field off_diff? boolean
---@field orphaned? boolean

---@class AgenticFlow.TreeRequest
---@field key? string
---@field review_generation integer
---@field open_generation? integer

---@class AgenticFlow.TreeHighlight
---@field line integer
---@field start_col integer
---@field end_col integer
---@field group string

---@class AgenticFlow.TreeOpenOptions: AgenticFlow.OpenOptions
---@field select_base? boolean

---@alias AgenticFlow.FileIconProvider fun(name: string): string?, string?

local namespace = vim.api.nvim_create_namespace("agentic-flow-tree")
---@type { buf: integer?, win: integer?, main_win: integer?, key: string?, config: AgenticFlow.Config?, nodes: table<integer, AgenticFlow.TreeNode>, folds: table<string, table<string, boolean>>, loading: boolean, ready: boolean, requested_base: string?, review_generation: integer, open_generation: integer }
local view = {
  buf = nil,
  win = nil,
  main_win = nil,
  key = nil,
  config = nil,
  nodes = {},
  folds = {},
  loading = false,
  ready = false,
  requested_base = nil,
  review_generation = 0,
  open_generation = 0,
}

---@type table<AgenticFlow.TreeStatus, { icon: string, highlight: string }>
local status_display = {
  pending = { icon = "○", highlight = "AgenticFlowTreePending" },
  partial = { icon = "◐", highlight = "AgenticFlowTreePartial" },
  invalidated = { icon = "↻", highlight = "AgenticFlowTreeInvalidated" },
  reviewed = { icon = "✓", highlight = "AgenticFlowTreeReviewed" },
}

---@return boolean
local function valid_buf()
  return view.buf ~= nil and vim.api.nvim_buf_is_valid(view.buf)
end

---@return boolean
local function valid_win()
  return view.win ~= nil and vim.api.nvim_win_is_valid(view.win)
end

---@return AgenticFlow.TreeRequest
local function capture_request()
  return {
    key = view.key,
    review_generation = view.review_generation,
  }
end

---@param request AgenticFlow.TreeRequest
---@return boolean
local function request_is_current(request)
  return request.key == view.key and request.review_generation == view.review_generation
end

---@param request AgenticFlow.TreeRequest
---@return boolean
local function open_request_is_current(request)
  return request_is_current(request) and request.open_generation == view.open_generation
end

---@param err? string
local function notify_error(err)
  util.notify(err or "Unknown review error", vim.log.levels.ERROR)
end

local function setup_highlights()
  vim.api.nvim_set_hl(0, "AgenticFlowTreeTitle", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "AgenticFlowTreeGuide", { default = true, link = "NonText" })
  vim.api.nvim_set_hl(0, "AgenticFlowTreeDirectory", { default = true, link = "Directory" })
  vim.api.nvim_set_hl(0, "AgenticFlowTreeDimmed", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "AgenticFlowTreePending", { default = true, link = "Normal" })
  vim.api.nvim_set_hl(0, "AgenticFlowTreePartial", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "AgenticFlowTreeInvalidated", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "AgenticFlowTreeReviewed", { default = true, link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "AgenticFlowTreeComment", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "AgenticFlowTreeOrphan", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "AgenticFlowTreeBadge", { default = true, link = "NonText" })
  vim.api.nvim_set_hl(0, "AgenticFlowTreeRefreshing", { default = true, link = "DiagnosticInfo" })
end

---@param line integer
---@param start_col integer
---@param end_col integer
---@param highlight string
local function set_mark(line, start_col, end_col, highlight)
  if end_col <= start_col then
    return
  end
  vim.api.nvim_buf_set_extmark(view.buf, namespace, line - 1, start_col, {
    end_col = end_col,
    hl_group = highlight,
  })
end

-- Optional cosmetic icon provider: whichever of `mini.icons` or
-- `nvim-web-devicons` the user already has, resolved once per open. Nil means
-- neither is installed and the tree renders exactly as it otherwise would.
---@type AgenticFlow.FileIconProvider?
local file_icon

---@return AgenticFlow.FileIconProvider?
local function mini_icons()
  local ok, mini = pcall(require, "mini.icons")
  if not ok or type(mini) ~= "table" or type(mini.get) ~= "function" then
    return nil
  end
  return function(name)
    local got, icon, highlight = pcall(mini.get, "file", name)
    if not got or type(icon) ~= "string" then
      return nil
    end
    return icon, highlight
  end
end

---@return AgenticFlow.FileIconProvider?
local function web_devicons()
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if not ok or type(devicons) ~= "table" or type(devicons.get_icon) ~= "function" then
    return nil
  end
  return function(name)
    local icon, highlight = devicons.get_icon(name, name:match("%.([^.]+)$"), { default = true })
    if type(icon) ~= "string" then
      return nil
    end
    return icon, highlight
  end
end

---@return AgenticFlow.FileIconProvider?
local function resolve_file_icon()
  return mini_icons() or web_devicons()
end

---@return AgenticFlow.TreeContainer
local function tree_root()
  return { directories = {}, files = {} }
end

---@param root AgenticFlow.TreeContainer
---@param file string
---@param change? AgenticFlow.Change
---@param orphaned? boolean the file's comments were stranded when it left the diff
local function insert_file(root, file, change, orphaned)
  local parts = vim.split(file, "/", { plain = true })
  local parent = root
  local path = {}
  for index = 1, #parts - 1 do
    path[#path + 1] = parts[index]
    local name = parts[index]
    parent.directories[name] = parent.directories[name]
      or {
        name = name,
        path = table.concat(path, "/"),
        directories = {},
        files = {},
      }
    parent = parent.directories[name]
  end
  parent.files[#parent.files + 1] = {
    name = parts[#parts],
    file = file,
    change = change,
    orphaned = orphaned,
  }
end

---@param parent AgenticFlow.TreeContainer
---@return AgenticFlow.TreeEntry[]
local function sorted_entries(parent)
  local entries = {}
  for _, directory in pairs(parent.directories) do
    entries[#entries + 1] = { kind = "directory", name = directory.name, value = directory }
  end
  for _, file in ipairs(parent.files) do
    entries[#entries + 1] = { kind = "file", name = file.name, value = file }
  end
  -- **Tree order**, one level at a time: the same key that orders the change
  -- list orders these entries, so the two never drift apart.
  local keys = {}
  for _, entry in ipairs(entries) do
    keys[entry] = util.tree_key(entry.name, entry.kind == "directory")
  end
  table.sort(entries, function(left, right)
    return keys[left] < keys[right]
  end)
  return entries
end

---@param change AgenticFlow.Change
---@param fallback string
---@return string
local function renamed_label(change, fallback)
  if change.old_file and change.old_file ~= change.file then
    return change.old_file .. " → " .. change.file
  end
  return fallback
end

---@param lines string[]
---@param nodes AgenticFlow.TreeNode[]
---@param text string
---@param node AgenticFlow.TreeNode
---@return integer
local function append_line(lines, nodes, text, node)
  lines[#lines + 1] = text
  nodes[#lines] = node
  return #lines
end

---Collapsed directory paths for one context. Folds are per context so two
---repositories, or two branches of one, never inherit each other's shape.
---@param context_key string
---@return table<string, boolean>
local function folded_paths(context_key)
  view.folds[context_key] = view.folds[context_key] or {}
  return view.folds[context_key]
end

-- Guide glyphs connecting each entry to its parent, one pair per ancestor
-- level: an entry hangs off `├╴` or `└╴`, and the levels above it continue as
-- `│ ` while they still have entries to come. Top-level entries sit flush at
-- the left edge: there is no root line for a guide to hang off.
local guides = {
  middle = "├╴",
  last = "└╴",
  vertical = "│ ",
  blank = "  ",
}

---@param lines string[]
---@param nodes AgenticFlow.TreeNode[]
---@param parent AgenticFlow.TreeContainer
---@param prefix? string accumulated guide continuation; nil at the top level
---@param context AgenticFlow.Context
---@param highlights AgenticFlow.TreeHighlight[]
local function append_children(lines, nodes, parent, prefix, context, highlights)
  local entries = sorted_entries(parent)
  for index, item in ipairs(entries) do
    local last = index == #entries
    local guide = prefix and (prefix .. (last and guides.last or guides.middle)) or ""
    local child_prefix = prefix and (prefix .. (last and guides.blank or guides.vertical)) or ""
    if item.kind == "directory" then
      local directory = item.value
      local folded = folded_paths(context.key)[directory.path] == true
      local marker = folded and "▸" or "▾"
      -- Derived status: recomputed here on every draw, never stored. `↻` wins
      -- over every other state and reaches the root, so an agent rewriting
      -- something already signed off shows through a collapsed fold; the badge
      -- keeps reporting progress alongside it.
      local status, reviewed, total = review.directory_status(context, directory.path)
      local display = total > 0 and status_display[status] or nil
      local badge = total > 0 and ("  %d/%d"):format(reviewed, total) or ""
      local head = guide .. marker .. " " .. (display and (display.icon .. " ") or "")
      local label = directory.name .. "/"
      local text = head .. label .. badge
      local line = append_line(lines, nodes, text, {
        kind = "directory",
        path = directory.path,
        status = status,
      })
      if #guide > 0 then
        highlights[#highlights + 1] = {
          line = line,
          start_col = 0,
          end_col = #guide,
          group = "AgenticFlowTreeGuide",
        }
      end
      if display then
        highlights[#highlights + 1] = {
          line = line,
          start_col = #head - #display.icon - 1,
          end_col = #head - 1,
          group = display.highlight,
        }
      end
      highlights[#highlights + 1] = {
        line = line,
        start_col = #head,
        end_col = #head + #label,
        group = "AgenticFlowTreeDirectory",
      }
      if badge ~= "" then
        highlights[#highlights + 1] = {
          line = line,
          start_col = #text - #badge,
          end_col = #text,
          group = "AgenticFlowTreeBadge",
        }
      end
      if not folded then
        ---@cast directory AgenticFlow.TreeDirectory
        append_children(lines, nodes, directory, child_prefix, context, highlights)
      end
    else
      local change = item.value.change
      local icon, icon_highlight = nil, nil
      if file_icon then
        icon, icon_highlight = file_icon(item.value.name)
      end
      local status, display, badge, label
      if change then
        local _, reviewed, total
        status, _, reviewed, total = review.file_status(context, change.file)
        display = status_display[status]
        badge = status == "partial" and ("  %d/%d"):format(reviewed, total) or ""
        label = renamed_label(change, item.value.name)
      else
        badge = ""
        label = item.value.name
      end
      local orphaned = change == nil and item.value.orphaned
      local marker = display and display.icon
        or (orphaned and view.config.signs.stale or view.config.signs.comment)
      local head = guide .. marker .. " " .. (icon and (icon .. " ") or "")
      local text = head .. label .. badge
      local line = append_line(lines, nodes, text, {
        kind = "file",
        file = item.value.file,
        change = change,
        status = status,
        off_diff = change == nil,
        orphaned = orphaned or nil,
      })
      if #guide > 0 then
        highlights[#highlights + 1] = {
          line = line,
          start_col = 0,
          end_col = #guide,
          group = "AgenticFlowTreeGuide",
        }
      end
      highlights[#highlights + 1] = {
        line = line,
        start_col = #guide,
        end_col = #guide + #marker,
        group = display and display.highlight
          or (orphaned and "AgenticFlowTreeOrphan" or "AgenticFlowTreeComment"),
      }
      if icon and icon_highlight then
        highlights[#highlights + 1] = {
          line = line,
          start_col = #head - #icon - 1,
          end_col = #head - 1,
          group = icon_highlight,
        }
      end
      -- A reviewed file dims in place; nothing ever moves on toggle.
      if change and status == "reviewed" then
        highlights[#highlights + 1] = {
          line = line,
          start_col = #head,
          end_col = #text,
          group = "AgenticFlowTreeDimmed",
        }
      end
      if badge ~= "" then
        highlights[#highlights + 1] = {
          line = line,
          start_col = #text - #badge,
          end_col = #text,
          group = "AgenticFlowTreeBadge",
        }
      end
    end
  end
end

---The title lives in the winbar: a fixed header above the list, out of reach
---of the cursorline and never scrolled away. The base sits left and the
---progress counter right; `%<` up front makes a too-narrow window truncate the
---base's left edge rather than the counter.
---@param text string
---@param counter string
---@param refreshing boolean
local function set_title(text, counter, refreshing)
  if not valid_win() then
    return
  end
  ---@param part string
  ---@return string
  local function escape(part)
    return (part:gsub("%%", "%%%%"))
  end
  vim.wo[view.win].winbar = "%<%#AgenticFlowTreeTitle#"
    .. escape(text)
    .. "%=  "
    .. escape(counter)
    .. (refreshing and "  %#AgenticFlowTreeRefreshing#⟳" or "")
end

-- The sidebar is a list, not a document: the last entry is the bottom of the
-- world. Neovim will otherwise scroll any buffer until its final line sits at
-- the window's top — with the wheel that happens over an unfocused sidebar,
-- without so much as a cursor move — so the view is pinned back whenever a
-- scroll, or a fold collapsing beneath it, would reveal space past the tree.
-- Clamping only ever scrolls the view back down and the cursor can never sit
-- below the clamped bottom, so it stays where it was.
local function clamp_view()
  if not valid_win() or not valid_buf() then
    return
  end
  vim.api.nvim_win_call(view.win, function()
    -- `winheight()` counts text rows only; `nvim_win_get_height` would count
    -- the winbar title row too and leave the last entry unreachable.
    local height = vim.fn.winheight(0)
    local max_top = math.max(1, vim.api.nvim_buf_line_count(view.buf) - height + 1)
    if vim.fn.line("w0") > max_top then
      vim.fn.winrestview({ topline = max_top })
    end
  end)
end

---@param context? AgenticFlow.Context
local function draw(context)
  if not valid_buf() then
    return
  end

  local old_line = 1
  if valid_win() then
    old_line = vim.api.nvim_win_get_cursor(view.win)[1]
  end
  local lines = {}
  local nodes = {}
  local highlights = {}

  if not context then
    local base = view.requested_base or (view.config and view.config.base) or "?"
    set_title("Review vs " .. base, "0/0", true)
    append_line(lines, nodes, "Resolving review…", { kind = "loading" })
  else
    local reviewed_files, total_files = review.progress(context)
    local refreshing = view.loading or pipeline.refreshing(context.key)
    -- An inferred base reads as inferred: it was never chosen for this branch
    -- and is not remembered, so the title is the only place the user can
    -- notice it. A carried-over base says so in its own words — it came from
    -- the branch left behind, which is a different claim from a guess.
    local inferred = { guess = " (guessed)", fallback = " (carried over)" }
    local base = context.base .. (inferred[context.base_source] or "")
    set_title("Review vs " .. base, ("%d/%d"):format(reviewed_files, total_files), refreshing)

    -- One path-ordered tree: every directory appears exactly once and review
    -- state never changes a line's position.
    local root = tree_root()
    for _, change in ipairs(context.changes) do
      insert_file(root, change.file, change)
    end
    -- A file outside the diff earns a line as soon as it holds a comment, and
    -- both kinds count: an **off-diff comment** was put there deliberately, an
    -- **orphan comment** was stranded when its file left the diff. Orphans are
    -- the ones most easily forgotten, so excluding them would defeat the point
    -- of showing either — but they are flagged, because an orphan means the
    -- ground moved under a note and a deliberate one means nothing happened.
    for file, file_entry in pairs(context.session.files) do
      local comments = file_entry.comments or {}
      if not context.by_file[file] and #comments > 0 then
        local orphaned = false
        for _, comment in ipairs(comments) do
          if comment.off_diff ~= true then
            orphaned = true
            break
          end
        end
        insert_file(root, file, nil, orphaned)
      end
    end
    append_children(lines, nodes, root, nil, context, highlights)
  end

  vim.bo[view.buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(view.buf, namespace, 0, -1)
  for _, highlight in ipairs(highlights) do
    set_mark(highlight.line, highlight.start_col, highlight.end_col, highlight.group)
  end
  vim.bo[view.buf].modifiable = false
  view.nodes = nodes

  -- The tree is stable, so the cursor stays where it is; it only moves when
  -- the buffer shrank out from under it.
  if valid_win() then
    local target = math.min(old_line, math.max(1, #lines))
    if target ~= old_line then
      vim.api.nvim_win_set_cursor(view.win, { target, 0 })
    end
    clamp_view()
  end
end

-- A wheel notch moves the selection rather than the viewport, because a list
-- scrolls by changing which item you are on. `vim.on_key` is the only hook that
-- sees a wheel event aimed at a window the user is not focused in — mappings
-- resolve against the focused buffer, so a buffer-local one never fires for a
-- pointer parked over the sidebar — and returning an empty string consumes the
-- key before Neovim scrolls anything.
local wheel_namespace = vim.api.nvim_create_namespace("agentic-flow-tree-wheel")
local wheel_keys = {
  [vim.keycode("<ScrollWheelDown>")] = 1,
  [vim.keycode("<ScrollWheelUp>")] = -1,
}

---Move the tree selection by `delta` lines, as one wheel notch does.
---@param delta integer
function M.wheel(delta)
  if not valid_win() or not valid_buf() then
    return
  end
  local line = vim.api.nvim_win_get_cursor(view.win)[1] + delta
  vim.api.nvim_win_set_cursor(view.win, {
    math.max(1, math.min(line, vim.api.nvim_buf_line_count(view.buf))),
    0,
  })
end

local function capture_wheel()
  vim.on_key(function(key, typed)
    local direction = wheel_keys[typed or key]
    if not direction or not valid_win() or vim.fn.getmousepos().winid ~= view.win then
      return
    end
    -- `mousescroll` is the user's own tuning of how far a notch travels.
    local step = tonumber(vim.o.mousescroll:match("ver:(%d+)")) or 3
    vim.schedule(function()
      M.wheel(direction * step)
    end)
    return ""
  end, wheel_namespace)
end

---@return AgenticFlow.TreeNode?
local function selected_node()
  if not valid_win() then
    return nil
  end
  return view.nodes[vim.api.nvim_win_get_cursor(view.win)[1]]
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
---@param change AgenticFlow.Change
---@return integer
local function first_unreviewed_line(context, change)
  for _, hunk in ipairs(change.hunks or {}) do
    if not review.hunk_reviewed(context, change.file, hunk) then
      return change.status == "D" and hunk.old_anchor or hunk.anchor
    end
  end
  return change.line or 1
end

---@return integer?
local function editing_window()
  if view.main_win and vim.api.nvim_win_is_valid(view.main_win) then
    return view.main_win
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= view.win then
      view.main_win = win
      return win
    end
  end
end

---@param context AgenticFlow.Context
---@param file string
---@param buf integer
---@param line integer
local function finish_open(context, file, buf, line)
  local win = editing_window()
  if not win or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_win_set_buf(win, buf)
  set_buffer_context(buf, context, file)
  signs.attach(view.config, context, file, buf)
  line = math.max(1, math.min(line, math.max(1, vim.api.nvim_buf_line_count(buf))))
  vim.api.nvim_win_set_cursor(win, { line, 0 })
  vim.api.nvim_set_current_win(win)
end

---@param context AgenticFlow.Context
---@param change AgenticFlow.Change
---@param line integer
---@param request AgenticFlow.TreeRequest
local function open_deleted(context, change, line, request)
  git.file_at(
    context.root,
    context.merge_base,
    change.old_file or change.file,
    function(contents, err)
      vim.schedule(function()
        if not open_request_is_current(request) or pipeline.get(request.key) ~= context then
          return
        end
        if not contents then
          return notify_error(err)
        end
        local buf = vim.api.nvim_create_buf(false, true)
        local name = "agentic-flow://deleted/" .. change.file
        pcall(vim.api.nvim_buf_set_name, buf, name)
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].bufhidden = "wipe"
        vim.bo[buf].swapfile = false
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, util.split_lines(contents))
        vim.bo[buf].modifiable = false
        vim.bo[buf].readonly = true
        local filetype = vim.filetype.match({ filename = change.file })
        if filetype then
          vim.bo[buf].filetype = filetype
        end
        finish_open(context, change.file, buf, line)
      end)
    end
  )
end

---@param context AgenticFlow.Context
local function finalize_open(context)
  if not valid_buf() then
    return
  end
  view.key = context.key
  view.loading = false
  view.ready = true
  view.requested_base = nil
  draw(context)
end

---Point the sidebar at a freshly resolved context. The context it was showing
---before stays cached, and an open whose generation has been superseded is
---simply dropped.
---@param opts AgenticFlow.TreeOpenOptions
local function start_review(opts)
  local previous_key = view.key
  view.review_generation = view.review_generation + 1
  view.open_generation = view.open_generation + 1
  local generation = view.review_generation
  view.loading = true
  view.requested_base = opts.base
  draw(pipeline.get(previous_key))
  pipeline.open(view.config, opts, function(context, err, dormant)
    if generation ~= view.review_generation then
      return
    end
    if not context then
      view.loading = false
      draw(pipeline.get(previous_key))
      if dormant then
        return M.select_base(opts.root)
      end
      return notify_error(err)
    end
    finalize_open(context)
    if opts.select_base then
      vim.schedule(function()
        if generation == view.review_generation then
          M.select_base(context.root)
        end
      end)
    end
  end)
end

---@param buf integer
local function setup_keymaps(buf)
  local mappings = {
    ["<CR>"] = M.open_entry,
    r = M.toggle_entry,
    h = M.toggle_fold,
    c = M.comment_entry,
    b = M.select_base,
    l = M.open_comments,
    y = M.copy_comments,
    D = M.toggle_diff,
    R = M.refresh,
    q = M.close,
  }
  for lhs, callback in pairs(mappings) do
    vim.keymap.set("n", lhs, callback, { buffer = buf, silent = true, nowait = true })
  end
end

local function create_window()
  view.main_win = vim.api.nvim_get_current_win()
  vim.cmd("topleft 36vnew")
  view.win = vim.api.nvim_get_current_win()
  view.buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(view.buf, "agentic-flow://review")
  vim.bo[view.buf].buftype = "nofile"
  vim.bo[view.buf].bufhidden = "wipe"
  vim.bo[view.buf].swapfile = false
  vim.bo[view.buf].modifiable = false
  vim.bo[view.buf].filetype = "agentic-flow-tree"
  vim.wo[view.win].number = false
  vim.wo[view.win].relativenumber = false
  vim.wo[view.win].signcolumn = "no"
  vim.wo[view.win].foldcolumn = "0"
  vim.wo[view.win].wrap = false
  vim.wo[view.win].cursorline = true
  -- Padding around the cursor is padding into empty space at the end of a
  -- list, and it is the cursor-driven half of what `clamp_view` pins back.
  vim.wo[view.win].scrolloff = 0
  vim.wo[view.win].winfixwidth = true
  setup_keymaps(view.buf)
  capture_wheel()
end

local function ensure_autocommands()
  local group = vim.api.nvim_create_augroup("AgenticFlowTree", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = setup_highlights,
  })
  -- Two events, because one is not enough. `WinScrolled` catches each scroll,
  -- but Neovim raises it between batches of pending input rather than per
  -- keystroke: a flicked wheel or a held `<C-e>` outruns it and settles a line
  -- or two past the end. `SafeState` fires once the input queue is drained, so
  -- it is the one that has the last word. Both are registered here rather than
  -- beside the window so they survive a reopen — the group is cleared on every
  -- open, and the window is only created when there is not one already.
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function(args)
      if valid_win() and args.match == tostring(view.win) then
        clamp_view()
      end
    end,
  })
  vim.api.nvim_create_autocmd("SafeState", {
    group = group,
    callback = clamp_view,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AgenticFlowContextRefreshed",
    callback = function(args)
      if args.data and args.data.key == view.key and valid_buf() then
        local context = pipeline.get(args.data.key)
        if context then
          draw(context)
        end
      end
    end,
  })
  -- A checkout moves the context to a new key. The sidebar follows it in place
  -- rather than emptying: the branch on disk is what the user is looking at.
  -- Folds are keyed by context, so they are carried over too — otherwise every
  -- checkout would silently expand a tree the user had collapsed.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AgenticFlowContextMigrated",
    callback = function(args)
      if not (args.data and args.data.from == view.key) then
        return
      end
      local context = pipeline.get(args.data.to)
      if not context then
        return
      end
      if args.data.reason == "checkout" then
        view.folds[context.key] =
          vim.tbl_extend("force", folded_paths(context.key), folded_paths(args.data.from))
      end
      view.key = args.data.to
      if valid_buf() then
        draw(context)
      end
    end,
  })
  -- ReviewClosed means the context was evicted, not that the user closed
  -- anything: the sidebar has nothing left to project, so it goes away.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AgenticFlowReviewClosed",
    callback = function(args)
      if args.data and args.data.key == view.key and valid_win() then
        view.ready = false
        M.close()
      end
    end,
  })
end

---Open the sidebar and asynchronously resolve its review context.
---@param config AgenticFlow.Config
---@param opts? AgenticFlow.TreeOpenOptions
---@return integer?
function M.open(config, opts)
  opts = opts or {}
  view.config = config
  view.ready = false
  file_icon = resolve_file_icon()
  setup_highlights()
  ensure_autocommands()
  if not valid_win() then
    create_window()
  end
  local current = pipeline.get(view.key)
  local root = opts.root or (current and current.root) or vim.fn.getcwd()
  local migrate_from = opts.migrate_from
  if not migrate_from and opts.base and current and current.root == vim.fs.normalize(root) then
    migrate_from = current.key
  end
  start_review({
    root = root,
    base = opts.base,
    remember_base = opts.remember_base,
    migrate_from = migrate_from,
    select_base = opts.select_base,
  })
  return view.buf
end

---The sidebar is considered open once its initial async context is ready.
---@return boolean
function M.is_open()
  return valid_win() and view.ready
end

---@return integer?
function M.buf()
  return valid_buf() and view.buf or nil
end

---@return integer?
function M.win()
  return valid_win() and view.win or nil
end

---@param line? integer
---@return AgenticFlow.TreeNode?
function M.node_at(line)
  if not line and valid_win() then
    line = vim.api.nvim_win_get_cursor(view.win)[1]
  end
  return line and view.nodes[line] or nil
end

---Collapse or expand the directory under the tree cursor.
function M.toggle_fold()
  local node = selected_node()
  if not node or node.kind ~= "directory" then
    return
  end
  local folded = folded_paths(view.key)
  folded[node.path] = not folded[node.path]
  draw(pipeline.get(view.key))
end

-- Unmarking more files than this confirms first. There is no undo anywhere in
-- the plugin and `reviewed_at` stamps cannot be reconstructed, and a collapsed
-- fold means the user may not see how many files a directory holds. Marking is
-- never confirmed: pressing `r` again undoes it.
local unmark_confirm_limit = 5

---Fan a mark out over every file beneath a directory, confirming first when
---the direction is the destructive one.
---@param context AgenticFlow.Context
---@param path string
---@return { directory: string, status: "reviewed"|"pending", files: string[] }? result
---@return string? err
local function toggle_directory(context, path)
  local files = review.directory_files(context, path)
  if #files == 0 then
    return nil
  end
  if review.directory_status(context, path) ~= "reviewed" or #files <= unmark_confirm_limit then
    return pipeline.toggle_directory(view.key, path)
  end
  local request = capture_request()
  vim.ui.select({ "Unmark", "Cancel" }, {
    prompt = ("Unmark %d reviewed files under %s/?"):format(#files, path),
  }, function(choice)
    if choice == "Unmark" and request_is_current(request) then
      pipeline.toggle_directory(request.key, path)
    end
  end)
  return nil
end

---Toggle the reviewed state of the entry under the cursor: one file, or every
---file beneath a directory.
---@return { file: string, status: "reviewed"|"pending" }|{ directory: string, status: "reviewed"|"pending", files: string[] }? result
---@return string? err
function M.toggle_entry()
  local node = selected_node()
  local context = pipeline.get(view.key)
  if not node or not context then
    return nil
  end
  if node.kind == "directory" then
    return toggle_directory(context, node.path)
  end
  if node.kind ~= "file" then
    return nil
  end
  if not node.change then
    return nil
  end
  return pipeline.toggle_file(view.key, node.change.file)
end

---@param context AgenticFlow.Context
---@param change AgenticFlow.Change
---@param line integer
---@return boolean
local function retarget_diff(context, change, line)
  local diff = package.loaded["agentic-flow.diff"]
  if
    type(diff) == "table"
    and type(diff.is_open) == "function"
    and diff.is_open()
    and type(diff.retarget) == "function"
  then
    diff.retarget(view.config, context, change.file, line)
    return true
  end
  return false
end

---Open the selected file in the editing window at its first unreviewed hunk.
---On a directory there is nothing to open, so `<CR>` toggles its fold instead.
function M.open_entry()
  local node = selected_node()
  if node and node.kind == "directory" then
    return M.toggle_fold()
  end
  local context = pipeline.get(view.key)
  if not node or node.kind ~= "file" or not context then
    return
  end
  local file = node.file or (node.change and node.change.file)
  local change = file and context.by_file[file] or nil
  local line
  if change then
    line = first_unreviewed_line(context, change)
  else
    local file_entry = file and context.session.files[file] or nil
    local first_comment = file_entry and (file_entry.comments or {})[1] or nil
    line = first_comment and first_comment.start_line or 1
  end
  view.open_generation = view.open_generation + 1
  local request = capture_request()
  request.open_generation = view.open_generation
  if change and retarget_diff(context, change, line) then
    return
  end
  if change and change.status == "D" then
    return open_deleted(context, change, line, request)
  end

  ---@cast file -nil
  local win = editing_window()
  if not win then
    return notify_error("Could not find the main editing window")
  end
  local ok, err = pcall(vim.api.nvim_win_call, win, function()
    vim.cmd.edit(vim.fn.fnameescape(util.absolute(context.root, file)))
  end)
  if not ok then
    return notify_error(err)
  end
  finish_open(context, file, vim.api.nvim_win_get_buf(win), line)
end

---Pick a local or remote branch without checking it out.
---@param root string
---@param callback fun(base: string?, err: string?)
function M.pick_base(root, callback)
  git.branches(root, function(branches, err)
    vim.schedule(function()
      if not branches then
        return callback(nil, err)
      end
      vim.ui.select(branches, {
        prompt = "Review base",
        format_item = function(item)
          local suffix = item.subject ~= "" and ("  " .. item.subject) or ""
          return item.name .. suffix
        end,
      }, function(choice)
        callback(choice and choice.name or nil)
      end)
    end)
  end)
end

---Pick and remember a new comparison base for the context in the sidebar.
---Picking never changes HEAD; the chosen ref is only passed back through the
---pipeline.
---@param root? string allows a dormant sidebar to pick before a context exists
function M.select_base(root)
  local context = pipeline.get(view.key)
  root = root or (context and context.root)
  if not root then
    return
  end
  local request = capture_request()
  M.pick_base(root, function(base, err)
    if not request_is_current(request) then
      return
    end
    if err then
      return notify_error(err)
    end
    if base then
      start_review({
        root = root,
        base = base,
        remember_base = true,
        migrate_from = context and context.root == root and context.key or nil,
      })
    elseif not context then
      M.close()
    end
  end)
end

---Refresh the sidebar's review context and immediately expose its in-flight
---state in the title. The completion event performs the final redraw.
---@param callback? fun(context: AgenticFlow.Context?, err: string?)
function M.refresh(callback)
  local context = pipeline.get(view.key)
  if not context then
    return
  end
  pipeline.refresh(function(refreshed, err)
    if not refreshed then
      notify_error(err)
    end
    if callback then
      callback(refreshed, err)
    end
  end, view.key)
  draw(context)
end

---Create a file-level comment in the multiline comments editor.
---@return integer?
function M.comment_entry()
  local node = selected_node()
  local context = pipeline.get(view.key)
  if not node or node.kind ~= "file" or not context then
    return
  end
  return require("agentic-flow.comments_ui").create(view.config, context, {
    ---@diagnostic disable-next-line: assign-type-mismatch
    file = node.file or (node.change and node.change.file),
  })
end

---Open the review-wide comments list.
---@return integer?
function M.open_comments()
  local context = pipeline.get(view.key)
  if not context then
    return
  end
  return require("agentic-flow.comments_ui").open(view.config, context)
end

---Copy every review comment to the configured register.
---@return string?
function M.copy_comments()
  local context = pipeline.get(view.key)
  if not context then
    return nil
  end
  local output, err, count = review.copy_comments(context, view.config.clipboard)
  if not output then
    ---@cast err string
    util.notify(err, vim.log.levels.WARN)
    return nil
  end
  util.notify(("%d review %s copied"):format(count, count == 1 and "comment" or "comments"))
  return output
end

---Toggle the sticky diff view for the selected file.
function M.toggle_diff()
  local node = selected_node()
  local context = pipeline.get(view.key)
  if not node or node.kind ~= "file" or not node.change or not context then
    return
  end
  local change = context.by_file[node.change.file]
  if not change then
    return
  end
  require("agentic-flow.diff").toggle(
    view.config,
    context,
    change.file,
    first_unreviewed_line(context, change)
  )
end

---Close the sidebar window. The review context outlives the window that
---happened to show it.
function M.close()
  local win = view.win
  vim.on_key(nil, wheel_namespace)
  view.ready = false
  view.loading = false
  view.review_generation = view.review_generation + 1
  view.open_generation = view.open_generation + 1
  view.key = nil
  view.nodes = {}
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  view.buf = nil
  view.win = nil
  view.main_win = nil
end

return M
