--- Schema v3 persistence. All functions are keyed by an explicit storage
--- directory (`git rev-parse --git-path agentic-flow`, resolved by the
--- pipeline) so this layer never talks to git itself.
---
--- v3 changes `reviewed_hunks` from `fingerprint -> true` to
--- `fingerprint -> { reviewed_at }`. There is no migration code: files with
--- an older (or unparseable) schema are preserved as `.corrupt.<ts>` backups
--- and the session starts fresh; newer schemas load read-only.
---
--- Comment entries may carry `off_diff = true`. The backward-compatible field
--- records that the comment was deliberately created outside the diff, so a
--- reload can distinguish it from an orphan whose file later left the diff.

---The persisted review session for one `(branch, base)` pair.
---@class AgenticFlow.Session
---@field version integer
---@field branch string
---@field base string
---@field next_comment_id integer
---@field files table<string, AgenticFlow.FileEntry>
---@field _read_only? boolean set when the on-disk schema is newer than this plugin

---Per-file review state inside a session. `load` and the review layer's
---`entry` both normalize `comments` and `reviewed_hunks`, so readers may
---treat them as always present.
---@class AgenticFlow.FileEntry
---@field comments AgenticFlow.Comment[]
---@field reviewed_hunks table<string, { reviewed_at: integer }> keyed by hunk fingerprint
---@field reviewed? boolean whole-file flag for non-textual changes
---@field fingerprint? string change fingerprint at the time it was reviewed
---@field invalidated? boolean

---@class AgenticFlow.Comment
---@field id string
---@field path string repository-relative file the comment belongs to
---@field start_line? integer absent for file-level comments
---@field end_line? integer
---@field text string
---@field anchor? AgenticFlow.CommentAnchor
---@field stale boolean
---@field off_diff? boolean deliberately created outside the diff
---@field orphan? boolean derived at load time, never persisted
---@field created_at integer
---@field updated_at integer

---The commented lines plus one line of surrounding context, for re-anchoring
---after the buffer changes underneath the comment.
---@class AgenticFlow.CommentAnchor
---@field lines string[]
---@field before? string
---@field after? string

local util = require("agentic-flow.util")

local M = {}

local SCHEMA_VERSION = 3
local uv = vim.uv

---@param branch string
---@param base string
---@return AgenticFlow.Session
local function default_session(branch, base)
  return {
    version = SCHEMA_VERSION,
    branch = branch,
    base = base,
    next_comment_id = 1,
    files = {},
  }
end

---@param storage_dir string
---@param branch string
---@param base string
---@return string
local function session_path(storage_dir, branch, base)
  return storage_dir .. "/reviews/" .. vim.fn.sha256(branch .. "\0" .. base) .. ".json"
end

---@param storage_dir string
---@return string
local function config_path(storage_dir)
  return storage_dir .. "/config.json"
end

---@param path string
---@return string? backup
---@return string? err
local function preserve_corrupt(path)
  local backup = ("%s.corrupt.%d"):format(path, os.time())
  local ok, err = uv.fs_rename(path, backup)
  return ok and backup or nil, err
end

---Preserve an unusable session file and fall back to a fresh session.
---@param path string
---@param branch string
---@param base string
---@param reason string
---@return AgenticFlow.Session, string
local function preserved_session(path, branch, base, reason)
  local backup, backup_error = preserve_corrupt(path)
  if not backup then
    local fallback = default_session(branch, base)
    fallback._read_only = true
    return fallback,
      ("review state is %s and could not be preserved: %s"):format(
        reason,
        backup_error or "unknown error"
      )
  end
  return default_session(branch, base),
    ("%s review state was preserved at %s"):format(reason, backup)
end

---@param storage_dir string
---@param branch string
---@return string?
function M.remembered_base(storage_dir, branch)
  local data = util.read_json(config_path(storage_dir))
  return data and data.bases and data.bases[branch] or nil
end

---@param storage_dir string
---@param branch string
---@param base string
---@return boolean, string?
function M.remember_base(storage_dir, branch, base)
  local path = config_path(storage_dir)
  local data, decode_error = util.read_json(path)
  if decode_error then
    local _, backup_error = preserve_corrupt(path)
    if backup_error then
      return false, ("could not preserve corrupt base configuration: %s"):format(backup_error)
    end
  end
  data = data or { version = SCHEMA_VERSION, bases = {} }
  data.version = SCHEMA_VERSION
  data.bases = data.bases or {}
  data.bases[branch] = base
  return util.write_json(path, data)
end

---Load the session for `(branch, base)`. The second return value is a
---warning to surface to the user; the corrupt/older-schema paths naturally
---warn only once because the offending file is moved aside.
---@param storage_dir string
---@param branch string
---@param base string
---@return AgenticFlow.Session, string?
function M.load(storage_dir, branch, base)
  local path = session_path(storage_dir, branch, base)
  local session, decode_error = util.read_json(path)
  if decode_error then
    return preserved_session(path, branch, base, "corrupt")
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
  if session.version < SCHEMA_VERSION then
    return preserved_session(path, branch, base, "older-schema")
  end

  session.files = type(session.files) == "table" and session.files or {}
  session.next_comment_id = tonumber(session.next_comment_id) or 1
  for _, file_entry in pairs(session.files) do
    file_entry.comments = type(file_entry.comments) == "table" and file_entry.comments or {}
    file_entry.reviewed_hunks = type(file_entry.reviewed_hunks) == "table"
        and file_entry.reviewed_hunks
      or {}
  end
  return session
end

---@param storage_dir string
---@param session AgenticFlow.Session
---@return boolean, string?
function M.save(storage_dir, session)
  if session._read_only then
    return false, "review state is read-only because its schema is newer than this plugin"
  end
  session.version = SCHEMA_VERSION
  return util.write_json(session_path(storage_dir, session.branch, session.base), session)
end

return M
