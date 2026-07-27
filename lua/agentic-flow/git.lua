local util = require("agentic-flow.util")

local M = {}

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

---@param args string[]
---@param cwd? string
---@return string?, string?
function M.run(args, cwd)
  local command = { "git", "-c", "core.quotepath=false" }
  vim.list_extend(command, args)
  local result = vim.system(command, { cwd = cwd, text = true }):wait()
  if result.code ~= 0 then
    local message = vim.trim(result.stderr or "")
    return nil, message ~= "" and message or ("git exited with status %d"):format(result.code)
  end
  return result.stdout or ""
end

---@param cwd? string
---@return string?, string?
function M.root(cwd)
  local root, err = M.run({ "rev-parse", "--show-toplevel" }, cwd)
  if not root then
    return nil, err
  end
  return vim.fs.normalize(vim.trim(root))
end

---@param root string
---@return string
function M.branch(root)
  local branch = M.run({ "symbolic-ref", "--quiet", "--short", "HEAD" }, root)
  if branch and vim.trim(branch) ~= "" then
    return vim.trim(branch)
  end
  local commit = M.run({ "rev-parse", "--short", "HEAD" }, root)
  return "detached@" .. vim.trim(commit or "unknown")
end

---@param root string
---@param ref string
---@return boolean, string?
function M.validate_ref(root, ref)
  local _, err = M.run({ "rev-parse", "--verify", "--quiet", ref .. "^{commit}" }, root)
  return err == nil, err
end

---@param root string
---@param base string
---@return string?, string?
function M.merge_base(root, base)
  local commit, err = M.run({ "merge-base", base, "HEAD" }, root)
  return commit and vim.trim(commit) or nil, err
end

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

local function is_binary(contents)
  return contents and contents:find("\0", 1, true) ~= nil
end

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

local function first_changed_line(patch)
  return tonumber(patch:match("@@.-%+(%d+)")) or 1
end

local function binary_patch(patch)
  for _, line in ipairs(util.split_lines(patch)) do
    if line == "GIT binary patch" or line:match("^Binary files .+ differ$") then
      return true
    end
  end
  return false
end

---@param root string
---@param merge_base string
---@return table[]?, string?
function M.changes(root, merge_base)
  local output, err = M.run({
    "diff",
    "--name-status",
    "-z",
    "--find-renames",
    merge_base,
  }, root)
  if not output then
    return nil, err
  end

  local changes = parse_name_status(output)
  local by_file = {}
  for _, change in ipairs(changes) do
    by_file[change.file] = true
    local patch, patch_error = M.run({
      "diff",
      "--no-color",
      "--no-ext-diff",
      "--binary",
      "--find-renames",
      merge_base,
      "--",
      change.file,
    }, root)
    if not patch then
      return nil, patch_error
    end
    change.patch = patch
    change.binary = binary_patch(patch)
    change.line = first_changed_line(patch)
    change.fingerprint = vim.fn.sha256(
      table.concat({ change.raw_status, change.old_file or "", change.file, patch }, "\0")
    )
  end

  local untracked, untracked_error =
    M.run({ "ls-files", "--others", "--exclude-standard", "-z" }, root)
  if not untracked then
    return nil, untracked_error
  end
  for _, file in ipairs(vim.split(untracked, "\0", { plain = true, trimempty = true })) do
    if not by_file[file] then
      local contents = util.read_file(util.absolute(root, file)) or ""
      local patch, binary = untracked_patch(file, contents)
      changes[#changes + 1] = {
        file = file,
        status = "?",
        status_label = status_names["?"],
        raw_status = "??",
        patch = patch,
        binary = binary,
        line = 1,
        fingerprint = vim.fn.sha256(table.concat({ "??", file, contents }, "\0")),
      }
    end
  end

  table.sort(changes, function(left, right)
    return left.file < right.file
  end)
  return changes
end

---@param root string
---@return table[]?, string?
function M.branches(root)
  local output, err = M.run({
    "for-each-ref",
    "--format=%(refname:short)%1f%(objectname:short)%1f%(subject)",
    "refs/heads",
    "refs/remotes",
  }, root)
  if not output then
    return nil, err
  end

  local current = M.branch(root)
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
  return branches
end

---@param root string
---@return string?, string?
function M.storage_dir(root)
  local path, err = M.run({ "rev-parse", "--git-path", "agentic-flow" }, root)
  if not path then
    return nil, err
  end
  path = vim.trim(path)
  if not vim.startswith(path, "/") then
    path = util.absolute(root, path)
  end
  return vim.fs.normalize(path)
end

---@param root string
---@param merge_base string
---@param path string
---@return string?, string?
function M.file_at(root, merge_base, path)
  return M.run({ "show", merge_base .. ":" .. path }, root)
end

return M
