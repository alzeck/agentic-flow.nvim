local M = {}

local uv = vim.uv or vim.loop

---@param message string
---@param level? integer one of vim.log.levels
function M.notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "agentic-flow.nvim" })
end

---@param path string
---@return string?
function M.read_file(path)
  local handle = uv.fs_open(path, "r", 438)
  if not handle then
    return nil
  end

  local stat = uv.fs_fstat(handle)
  if not stat then
    uv.fs_close(handle)
    return nil
  end

  local data = uv.fs_read(handle, stat.size, 0)
  uv.fs_close(handle)
  return data
end

---@param path string
---@return table?, string?
function M.read_json(path)
  local contents = M.read_file(path)
  if not contents or contents == "" then
    return nil
  end

  local ok, decoded = pcall(vim.json.decode, contents)
  if not ok or type(decoded) ~= "table" then
    return nil, ok and "JSON root is not an object" or tostring(decoded)
  end
  return decoded
end

---@param path string
---@param value table
---@return boolean, string?
function M.write_json(path, value)
  local directory = vim.fs.dirname(path)
  if vim.fn.mkdir(directory, "p") == 0 and vim.fn.isdirectory(directory) == 0 then
    return false, ("could not create %s"):format(directory)
  end

  local ok, encoded = pcall(vim.json.encode, value)
  if not ok then
    return false, encoded
  end

  local temporary = ("%s.tmp.%d.%d"):format(path, vim.fn.getpid(), uv.hrtime())
  local handle, open_error = uv.fs_open(temporary, "w", 384)
  if not handle then
    return false, open_error
  end

  local wrote, write_error = uv.fs_write(handle, encoded .. "\n", 0)
  uv.fs_close(handle)
  if not wrote then
    uv.fs_unlink(temporary)
    return false, write_error
  end

  local renamed, rename_error = uv.fs_rename(temporary, path)
  if not renamed then
    uv.fs_unlink(temporary)
    return false, rename_error
  end
  return true
end

---@param value string
---@return string[]
function M.split_lines(value)
  local lines = vim.split(value, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

---@param root string
---@param path string
---@return string
function M.absolute(root, path)
  return vim.fs.normalize(root .. "/" .. path)
end

---@param path string
---@return string
local function resolved(path)
  path = vim.fs.normalize(path)
  local real = uv.fs_realpath(path)
  if real then
    return vim.fs.normalize(real)
  end
  local parent = vim.fs.dirname(path)
  local resolved_parent = parent and uv.fs_realpath(parent) or nil
  if resolved_parent then
    return vim.fs.normalize(resolved_parent .. "/" .. vim.fs.basename(path))
  end
  return path
end

-- **Tree order** as a plain string key: every segment carries a marker that
-- sorts directories (`!`, 0x21) ahead of files (`#`, 0x23) before its name is
-- ever compared, and each segment is built onto its parent's, so a directory's
-- whole subtree stays contiguous beneath it. Comparing keys byte for byte is
-- the entire rule, which is what lets the sidebar, unreviewed-hunk navigation
-- and comment export share one order without sharing any code.
---@param path string
---@param directory? boolean the final segment names a directory, not a file
---@return string
function M.tree_key(path, directory)
  local parts = vim.split(path, "/", { plain = true })
  local key = {}
  for index, part in ipairs(parts) do
    local marker = (index < #parts or directory) and "!" or "#"
    key[#key + 1] = marker .. part .. " "
  end
  return table.concat(key)
end

---@param root string
---@param path string
---@return string?
function M.relative(root, path)
  path = resolved(path)
  root = resolved(root)
  if path == root then
    return "."
  end
  local prefix = root .. "/"
  if path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end
  return nil
end

return M
