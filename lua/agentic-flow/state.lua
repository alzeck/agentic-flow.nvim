local git = require("agentic-flow.git")
local util = require("agentic-flow.util")

local M = {}

local SCHEMA_VERSION = 1
local uv = vim.uv or vim.loop

local function default_session(branch, base)
  return {
    version = SCHEMA_VERSION,
    branch = branch,
    base = base,
    next_comment_id = 1,
    files = {},
  }
end

local function paths(root, branch, base)
  local directory, err = git.storage_dir(root)
  if not directory then
    return nil, nil, err
  end
  local key = vim.fn.sha256(branch .. "\0" .. base)
  return directory .. "/config.json", directory .. "/reviews/" .. key .. ".json"
end

local function preserve_corrupt(path)
  local backup = ("%s.corrupt.%d"):format(path, os.time())
  local ok, err = uv.fs_rename(path, backup)
  return ok and backup or nil, err
end

---@param root string
---@param branch string
---@return string?
function M.remembered_base(root, branch)
  local config_path = paths(root, branch, "")
  if not config_path then
    return nil
  end
  local data = util.read_json(config_path)
  return data and data.bases and data.bases[branch] or nil
end

---@param root string
---@param branch string
---@param base string
---@return boolean, string?
function M.remember_base(root, branch, base)
  local config_path, _, err = paths(root, branch, base)
  if not config_path then
    return false, err
  end
  local data, decode_error = util.read_json(config_path)
  if decode_error then
    local _, backup_error = preserve_corrupt(config_path)
    if backup_error then
      return false, ("could not preserve corrupt base configuration: %s"):format(backup_error)
    end
  end
  data = data or { version = SCHEMA_VERSION, bases = {} }
  data.version = SCHEMA_VERSION
  data.bases = data.bases or {}
  data.bases[branch] = base
  return util.write_json(config_path, data)
end

---@param root string
---@param branch string
---@param base string
---@return table, string?
function M.load(root, branch, base)
  local _, session_path, err = paths(root, branch, base)
  if not session_path then
    return default_session(branch, base), err
  end

  local session, decode_error = util.read_json(session_path)
  if decode_error then
    local backup, backup_error = preserve_corrupt(session_path)
    if not backup then
      local fallback = default_session(branch, base)
      fallback._read_only = true
      return fallback,
        ("review state is corrupt and could not be preserved: %s"):format(
          backup_error or decode_error
        )
    end
    return default_session(branch, base),
      ("corrupt review state was preserved at %s"):format(backup)
  end
  if not session then
    return default_session(branch, base)
  end
  if type(session.version) ~= "number" or session.version > SCHEMA_VERSION then
    local fallback = default_session(branch, base)
    fallback._read_only = true
    return fallback,
      ("review state uses unsupported schema version %s"):format(tostring(session.version))
  end

  session.files = type(session.files) == "table" and session.files or {}
  session.next_comment_id = tonumber(session.next_comment_id) or 1
  return session
end

---@param root string
---@param session table
---@return boolean, string?
function M.save(root, session)
  if session._read_only then
    return false, "review state is read-only because its schema is newer than this plugin"
  end
  local _, session_path, err = paths(root, session.branch, session.base)
  if not session_path then
    return false, err
  end
  return util.write_json(session_path, session)
end

return M
