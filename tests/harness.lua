--- Shared helpers for the headless spec files under tests/.
--- Every spec builds its own fixture repository through this module; nothing
--- in here keeps global state, so specs stay order-independent.
local M = {}

local uv = vim.uv

---@param actual any
---@param expected any
---@param message string
function M.assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(
      ("%s\nexpected: %s\nactual: %s"):format(message, vim.inspect(expected), vim.inspect(actual)),
      2
    )
  end
end

---Assert that `value` is a string containing `needle` (plain match).
---@param value any
---@param needle string
---@param message string
function M.assert_contains(value, needle, message)
  if type(value) ~= "string" or not value:find(needle, 1, true) then
    error(
      ("%s\nexpected to contain: %s\nactual: %s"):format(message, needle, vim.inspect(value)),
      2
    )
  end
end

---Run a command, failing the spec unless it exits zero.
---@param cwd string
---@param ... string
---@return string trimmed stdout
function M.run(cwd, ...)
  local command = { ... }
  local result = vim.system(command, { cwd = cwd, text = true }):wait()
  assert(
    result.code == 0,
    ("command failed: %s\n%s"):format(table.concat(command, " "), result.stderr or "")
  )
  return vim.trim(result.stdout or "")
end

---@param path string
---@param lines string[]
function M.write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

---@param path string
---@param contents string raw bytes, may contain NUL
function M.write_bytes(path, contents)
  local handle = assert(uv.fs_open(path, "w", 420))
  assert(uv.fs_write(handle, contents, 0))
  uv.fs_close(handle)
end

---Create an empty throwaway repository on branch `main`.
---The path is realpath-resolved so specs behave on macOS, where tempdirs
---live behind the /var -> /private/var symlink.
---@return string root
function M.repo()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  root = vim.fs.normalize(assert(uv.fs_realpath(root)))
  M.run(root, "git", "init", "-b", "main")
  M.run(root, "git", "config", "user.email", "tests@example.com")
  M.run(root, "git", "config", "user.name", "Agentic Flow Tests")
  M.run(root, "git", "config", "commit.gpgsign", "false")
  return root
end

---Build the standard fixture: branch `feature` reviewed against `upstream`,
---covering committed, unstaged, staged, deleted, renamed, untracked, binary,
---and multi-hunk files.
---@return string root
function M.fixture_repo()
  local root = M.repo()
  M.write(root .. "/tracked.txt", { "alpha", "target", "omega" })
  M.write(root .. "/staged.txt", { "base" })
  M.write(root .. "/deleted.txt", { "deleted base line" })
  M.write(root .. "/rename-old.txt", { "rename me" })
  local hunk_lines = {}
  for index = 1, 20 do
    hunk_lines[index] = ("hunk line %d"):format(index)
  end
  M.write(root .. "/hunks.txt", hunk_lines)
  M.run(root, "git", "add", ".")
  M.run(root, "git", "commit", "-m", "base")
  M.run(root, "git", "branch", "upstream")
  M.run(root, "git", "checkout", "-b", "feature")

  M.write(root .. "/committed.txt", { "Binary files support file-level notes." })
  M.run(root, "git", "add", "committed.txt")
  M.run(root, "git", "commit", "-m", "feature commit")
  M.write(root .. "/tracked.txt", { "ALPHA", "target", "omega" })
  local changed = vim.deepcopy(hunk_lines)
  changed[2] = "changed hunk two"
  changed[18] = "changed hunk eighteen"
  M.write(root .. "/hunks.txt", changed)
  M.write(root .. "/staged.txt", { "staged change" })
  M.run(root, "git", "add", "staged.txt")
  assert(uv.fs_unlink(root .. "/deleted.txt"))
  M.run(root, "git", "mv", "rename-old.txt", "rename-new.txt")
  M.write(root .. "/untracked.txt", { "untracked change" })
  M.write_bytes(root .. "/binary.dat", "before\0after")
  return root
end

---Block until `predicate` returns truthy, failing the spec on timeout.
---@param predicate fun(): any
---@param message? string
---@param timeout? number milliseconds, defaults to 5000
function M.wait(predicate, message, timeout)
  if not vim.wait(timeout or 5000, predicate, 10) then
    error(message or "timed out waiting for condition", 2)
  end
end

---Call `fn(..., callback)` and block until the callback fires, returning the
---callback's arguments. For testing callback-last async APIs.
---@param fn function
---@param ... any arguments to pass before the callback
---@return ...
function M.await(fn, ...)
  local results
  local args = { ... }
  args[#args + 1] = function(...)
    results = { n = select("#", ...), ... }
  end
  fn(unpack(args))
  M.wait(function()
    return results ~= nil
  end, "async call never completed")
  return unpack(results, 1, results.n)
end

return M
