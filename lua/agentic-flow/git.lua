--- Async git layer. Every function that runs git takes a callback as its
--- last argument; callbacks may fire in a fast event context, so callers that
--- touch the API must schedule. One batched diff pass serves a whole resolve.

---One parsed unified-diff hunk. Line numbers are 1-based buffer lines:
---`line_kinds`/`changed_lines` index the new side, `old_line_kinds`/
---`old_changed_lines` the old side, and the anchor fields carry each side's
---landing line for cursor movement.
---@class AgenticFlow.Hunk
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field changed_lines integer[] new-side lines introduced by "+" runs
---@field old_changed_lines integer[] old-side lines touched by "-" runs
---@field deletion_anchors integer[] new-side anchors of every deleted line
---@field deletion_sign_anchors integer[] new-side anchors of unpaired deletions
---@field line_kinds table<integer, "add"|"change">
---@field old_line_kinds table<integer, "change"|"delete">
---@field old_cursor_start integer
---@field old_cursor_end integer
---@field new_cursor_start integer
---@field new_cursor_end integer
---@field fingerprint string content hash suffixed with an occurrence counter
---@field anchor integer new-side landing line
---@field old_anchor integer old-side landing line

---One changed file between the merge-base and the worktree.
---@class AgenticFlow.Change
---@field file string current path, repository-relative
---@field old_file? string previous path, for renames and copies
---@field status string one-letter kind ("A", "M", "D", "R", "C", "T", "U", "?")
---@field status_label string human-readable status name
---@field raw_status string raw `--name-status` field (e.g. "R100")
---@field patch string per-file unified diff, "" when git produced none
---@field binary boolean
---@field hunks AgenticFlow.Hunk[]
---@field line integer default cursor line when opening the change
---@field fingerprint string identity hash of the change's content
---@field error? string why hunks are missing, when this file degraded

local util = require("agentic-flow.util")

local M = {}

local uv = vim.uv

local status_names = {
  A = "added",
  C = "copied",
  D = "deleted",
  M = "modified",
  R = "renamed",
  T = "type changed",
  U = "unmerged",
  ["?"] = "untracked",
}

---Run git asynchronously; the callback receives (stdout, err).
---@param args string[]
---@param cwd? string
---@param callback fun(stdout: string?, err: string?)
function M.run(args, cwd, callback)
  local command = { "git", "-c", "core.quotepath=false" }
  vim.list_extend(command, args)
  local ok, spawn_error = pcall(vim.system, command, { cwd = cwd, text = true }, function(result)
    if result.code ~= 0 then
      local message = vim.trim(result.stderr or "")
      callback(nil, message ~= "" and message or ("git exited with status %d"):format(result.code))
    else
      callback(result.stdout or "")
    end
  end)
  if not ok then
    vim.schedule(function()
      callback(nil, tostring(spawn_error))
    end)
  end
end

---@param cwd? string
---@param callback fun(root: string?, err: string?)
function M.root(cwd, callback)
  M.run({ "rev-parse", "--show-toplevel" }, cwd, function(output, err)
    if not output then
      return callback(nil, err)
    end
    local path = vim.trim(output)
    callback(vim.fs.normalize(uv.fs_realpath(path) or path))
  end)
end

---@param root string
---@param callback fun(branch: string)
function M.branch(root, callback)
  M.run({ "symbolic-ref", "--quiet", "--short", "HEAD" }, root, function(branch)
    if branch and vim.trim(branch) ~= "" then
      return callback(vim.trim(branch))
    end
    M.run({ "rev-parse", "--short", "HEAD" }, root, function(commit)
      callback("detached@" .. vim.trim(commit or "unknown"))
    end)
  end)
end

---@param root string
---@param ref string
---@param callback fun(valid: boolean, err: string?)
function M.validate_ref(root, ref, callback)
  M.run({ "rev-parse", "--verify", "--quiet", ref .. "^{commit}" }, root, function(_, err)
    callback(err == nil, err)
  end)
end

---The first ref in `candidates` that resolves to a commit. Candidates are
---verified one at a time, in order, and nothing past the winner is checked;
---an empty answer means none of them exist.
---@param root string
---@param candidates string[]
---@param callback fun(ref: string?, index: integer?)
function M.first_valid_ref(root, candidates, callback)
  ---@param index integer
  local function attempt(index)
    local ref = candidates[index]
    if not ref then
      return callback(nil)
    end
    M.validate_ref(root, ref, function(valid)
      if valid then
        return callback(ref, index)
      end
      attempt(index + 1)
    end)
  end
  attempt(1)
end

---@param root string
---@param base string
---@param callback fun(commit: string?, err: string?)
function M.merge_base(root, base, callback)
  M.run({ "merge-base", base, "HEAD" }, root, function(commit, err)
    callback(commit and vim.trim(commit) or nil, err)
  end)
end

---@param output string
---@return AgenticFlow.Change[] changes listing fields only; patch, hunks, line and fingerprint are filled in by build_changes
local function parse_name_status(output)
  local fields = vim.split(output, "\0", { plain = true, trimempty = true })
  local changes = {}
  local index = 1
  while index <= #fields do
    local raw_status = fields[index]
    local kind = raw_status:sub(1, 1)
    index = index + 1

    local old_file
    local file = fields[index]
    index = index + 1
    if kind == "R" or kind == "C" then
      old_file = file
      file = fields[index]
      index = index + 1
    end

    if file then
      changes[#changes + 1] = {
        file = file,
        old_file = old_file,
        status = kind,
        status_label = status_names[kind] or raw_status,
        raw_status = raw_status,
      }
    end
  end
  return changes
end

---@param contents? string
---@return boolean?
local function is_binary(contents)
  return contents and contents:find("\0", 1, true) ~= nil
end

---@param file string
---@param contents? string
---@return string patch
---@return boolean binary
local function untracked_patch(file, contents)
  if is_binary(contents) then
    return ("diff --git a/%s b/%s\nnew binary file\n"):format(file, file), true
  end

  local lines = util.split_lines(contents or "")
  local patch = {
    ("diff --git a/%s b/%s"):format(file, file),
    "new file mode 100644",
    "--- /dev/null",
    "+++ b/" .. file,
    ("@@ -0,0 +1,%d @@"):format(#lines),
  }
  for _, line in ipairs(lines) do
    patch[#patch + 1] = "+" .. line
  end
  return table.concat(patch, "\n") .. "\n", false
end

---@param start integer
---@param count integer
---@return integer first
---@return integer last
local function hunk_range(start, count)
  if count == 0 then
    return math.max(1, start), math.max(1, start)
  end
  return math.max(1, start), math.max(1, start + count - 1)
end

---@param values integer[]
---@return integer[]
local function unique_numbers(values)
  local result = {}
  local seen = {}
  for _, value in ipairs(values) do
    if not seen[value] then
      seen[value] = true
      result[#result + 1] = value
    end
  end
  return result
end

---@param hunks AgenticFlow.Hunk[]
---@param hunk? table in-progress hunk from parse_hunks; carries a transient body field the class does not declare
local function finish_hunk(hunks, hunk)
  if not hunk or (#hunk.changed_lines == 0 and #hunk.old_changed_lines == 0) then
    return
  end
  hunk.deletion_anchors = unique_numbers(hunk.deletion_anchors)
  hunk.deletion_sign_anchors = unique_numbers(hunk.deletion_sign_anchors)
  hunk.old_cursor_start, hunk.old_cursor_end = hunk_range(hunk.old_start, hunk.old_count)
  hunk.new_cursor_start, hunk.new_cursor_end = hunk_range(hunk.new_start, hunk.new_count)
  hunks[#hunks + 1] = hunk
end

---Parse standard unified-diff hunks.
---
---Beyond the header fields, each hunk classifies its lines for the sign
---engine: `line_kinds` maps new-side lines to "add"/"change" (a "+" run
---paired with a "-" run is a change, surplus additions are adds),
---`old_line_kinds` maps old-side lines to "change"/"delete", and
---`deletion_sign_anchors` holds the new-side anchors of unpaired deletions.
---@param patch string
---@return AgenticFlow.Hunk[]
function M.parse_hunks(patch)
  local hunks = {}
  local current
  local old_line
  local new_line
  -- The in-progress "-" run: old line numbers, their new-side anchors, and
  -- how many have been paired with "+" lines so far.
  local pending_old = {}
  local pending_anchors = {}
  local paired = 0

  local function flush_run()
    if not current then
      return
    end
    for index = paired + 1, #pending_old do
      current.old_line_kinds[pending_old[index]] = "delete"
      current.deletion_sign_anchors[#current.deletion_sign_anchors + 1] = pending_anchors[index]
    end
    pending_old = {}
    pending_anchors = {}
    paired = 0
  end

  for _, line in ipairs(util.split_lines(patch)) do
    local old_start, old_count, new_start, new_count =
      line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if old_start then
      flush_run()
      finish_hunk(hunks, current)
      old_start = tonumber(old_start)
      new_start = tonumber(new_start)
      old_count = old_count == "" and 1 or tonumber(old_count)
      new_count = new_count == "" and 1 or tonumber(new_count)
      current = {
        old_start = old_start,
        old_count = old_count,
        new_start = new_start,
        new_count = new_count,
        changed_lines = {},
        old_changed_lines = {},
        deletion_anchors = {},
        deletion_sign_anchors = {},
        line_kinds = {},
        old_line_kinds = {},
        body = {},
      }
      old_line = old_start
      new_line = new_start
    elseif current then
      local prefix = line:sub(1, 1)
      if prefix == " " then
        flush_run()
        current.body[#current.body + 1] = line
        old_line = old_line + 1
        new_line = new_line + 1
      elseif prefix == "-" then
        if paired > 0 then
          flush_run()
        end
        current.body[#current.body + 1] = line
        current.old_changed_lines[#current.old_changed_lines + 1] = old_line
        current.deletion_anchors[#current.deletion_anchors + 1] = math.max(1, new_line)
        pending_old[#pending_old + 1] = old_line
        pending_anchors[#pending_anchors + 1] = math.max(1, new_line)
        old_line = old_line + 1
      elseif prefix == "+" then
        current.body[#current.body + 1] = line
        current.changed_lines[#current.changed_lines + 1] = new_line
        if paired < #pending_old then
          paired = paired + 1
          current.line_kinds[new_line] = "change"
          current.old_line_kinds[pending_old[paired]] = "change"
        else
          current.line_kinds[new_line] = "add"
        end
        new_line = new_line + 1
      elseif prefix == "\\" then
        current.body[#current.body + 1] = line
      end
    end
  end
  flush_run()
  finish_hunk(hunks, current)

  local occurrences = {}
  for _, hunk in ipairs(hunks) do
    local content_hash = vim.fn.sha256(table.concat(hunk.body, "\n"))
    occurrences[content_hash] = (occurrences[content_hash] or 0) + 1
    hunk.fingerprint = ("%s:%d"):format(content_hash, occurrences[content_hash])
    hunk.body = nil
    hunk.anchor = hunk.changed_lines[1] or hunk.deletion_anchors[1] or math.max(1, hunk.new_start)
    hunk.old_anchor = hunk.old_changed_lines[1] or math.max(1, hunk.old_start)
  end
  return hunks
end

---Split one batched `git diff` into per-file sections keyed by current path.
---@param output string
---@return table<string, { patch: string, binary: boolean }>
local function split_batched_diff(output)
  local sections = {}
  local lines = util.split_lines(output)
  local current

  local function finalize()
    if not current then
      return
    end
    local path = current.rename_to or current.new_path or current.old_path or current.fallback
    if path then
      sections[path] = {
        patch = table.concat(current.lines, "\n") .. "\n",
        binary = current.binary or false,
      }
    end
    current = nil
  end

  for _, line in ipairs(lines) do
    if line:match("^diff %-%-git ") then
      finalize()
      current = {
        lines = { line },
        header = true,
        fallback = line:match("^diff %-%-git a/(.+) b/") or nil,
      }
    elseif current then
      current.lines[#current.lines + 1] = line
      if current.header then
        if line:match("^@@ ") then
          current.header = false
        elseif line == "GIT binary patch" or line:match("^Binary files .+ differ$") then
          current.binary = true
        else
          current.rename_to = line:match("^rename to (.+)$")
            or line:match("^copy to (.+)$")
            or current.rename_to
          current.new_path = line:match("^%+%+%+ b/(.+)$") or current.new_path
          current.old_path = line:match("^%-%-%- a/(.+)$") or current.old_path
        end
      end
    end
  end
  finalize()
  return sections
end

---Combine the three raw listings into the change table.
---@param root string
---@param name_status string
---@param batched_diff string
---@param untracked_listing string
---@return AgenticFlow.Change[]
local function build_changes(root, name_status, batched_diff, untracked_listing)
  local changes = parse_name_status(name_status)
  local sections = split_batched_diff(batched_diff)
  local by_file = {}

  for _, change in ipairs(changes) do
    by_file[change.file] = true
    local section = sections[change.file]
    if section then
      change.patch = section.patch
      change.binary = section.binary
      change.hunks = change.binary and {} or M.parse_hunks(section.patch)
    else
      -- Degrade this file only: keep the listing entry, flag it, no hunks.
      change.patch = ""
      change.binary = false
      change.hunks = {}
      change.error = "git produced no diff for this file"
    end
    change.line = change.status == "D" and (change.hunks[1] and change.hunks[1].old_anchor or 1)
      or (change.hunks[1] and change.hunks[1].anchor or 1)
    change.fingerprint = vim.fn.sha256(
      table.concat({ change.raw_status, change.old_file or "", change.file, change.patch }, "\0")
    )
  end

  for _, file in ipairs(vim.split(untracked_listing, "\0", { plain = true, trimempty = true })) do
    if not by_file[file] then
      local contents = util.read_file(util.absolute(root, file))
      if contents then
        local patch, binary = untracked_patch(file, contents)
        changes[#changes + 1] = {
          file = file,
          status = "?",
          status_label = status_names["?"],
          raw_status = "??",
          patch = patch,
          binary = binary,
          hunks = binary and {} or M.parse_hunks(patch),
          line = 1,
          fingerprint = vim.fn.sha256(table.concat({ "??", file, contents }, "\0")),
        }
      else
        changes[#changes + 1] = {
          file = file,
          status = "?",
          status_label = status_names["?"],
          raw_status = "??",
          patch = "",
          binary = false,
          hunks = {},
          line = 1,
          error = "could not read the untracked file",
          fingerprint = vim.fn.sha256(table.concat({ "??", file }, "\0")),
        }
      end
    end
  end

  -- Changes arrive in **tree order** rather than raw path order, so walking
  -- this list — which is how unreviewed-hunk navigation moves — travels the
  -- sidebar top to bottom.
  local keys = {}
  for _, change in ipairs(changes) do
    keys[change] = util.tree_key(change.file)
  end
  table.sort(changes, function(left, right)
    return keys[left] < keys[right]
  end)
  return changes
end

---Collect every change between the merge-base and the worktree in one pass:
---one `--name-status`, one full batched diff (so renames keep their old path
---in scope and produce rename patches), and one untracked listing.
---@param root string
---@param merge_base string
---@param callback fun(changes: AgenticFlow.Change[]?, err: string?)
function M.changes(root, merge_base, callback)
  local results = {}
  local first_error
  local remaining = 3

  ---@param key string
  ---@return fun(output: string?, err: string?)
  local function collect(key)
    return function(output, err)
      results[key] = output
      first_error = first_error or err
      remaining = remaining - 1
      if remaining > 0 then
        return
      end
      -- Parsing needs vim.fn (sha256), which is off-limits in a fast event
      -- context, so completion always lands on the main loop.
      vim.schedule(function()
        if first_error then
          return callback(nil, first_error)
        end
        callback(build_changes(root, results.names, results.diff, results.untracked))
      end)
    end
  end

  M.run({ "diff", "--name-status", "-z", "--find-renames", merge_base }, root, collect("names"))
  -- Default context can merge nearby visible change clusters into one hunk.
  -- Review zero-context hunks so every independently signed cluster toggles independently.
  M.run({
    "diff",
    "--no-color",
    "--no-ext-diff",
    "--binary",
    "--find-renames",
    "--unified=0",
    "--inter-hunk-context=0",
    merge_base,
  }, root, collect("diff"))
  M.run({ "ls-files", "--others", "--exclude-standard", "-z" }, root, collect("untracked"))
end

---@param root string
---@param callback fun(branches: { name: string, commit: string, subject: string, current: boolean }[]?, err: string?)
function M.branches(root, callback)
  M.run(
    {
      "for-each-ref",
      "--format=%(refname:short)%1f%(objectname:short)%1f%(subject)",
      "refs/heads",
      "refs/remotes",
    },
    root,
    function(output, err)
      if not output then
        return callback(nil, err)
      end
      M.branch(root, function(current)
        local branches = {}
        for _, line in ipairs(util.split_lines(output)) do
          local name, commit, subject = line:match("^([^\31]+)\31([^\31]+)\31(.*)$")
          if name and not name:match("/HEAD$") then
            branches[#branches + 1] = {
              name = name,
              commit = commit,
              subject = subject,
              current = name == current,
            }
          end
        end
        table.sort(branches, function(left, right)
          if left.current ~= right.current then
            return left.current
          end
          return left.name < right.name
        end)
        callback(branches)
      end)
    end
  )
end

---@param root string
---@param callback fun(path: string?, err: string?)
function M.storage_dir(root, callback)
  M.run({ "rev-parse", "--git-path", "agentic-flow" }, root, function(output, err)
    if not output then
      return callback(nil, err)
    end
    local path = vim.trim(output)
    if not vim.startswith(path, "/") then
      path = util.absolute(root, path)
    end
    callback(vim.fs.normalize(path))
  end)
end

---@param root string
---@param merge_base string
---@param path string
---@param callback fun(contents: string?, err: string?)
function M.file_at(root, merge_base, path, callback)
  M.run({ "show", merge_base .. ":" .. path }, root, callback)
end

return M
