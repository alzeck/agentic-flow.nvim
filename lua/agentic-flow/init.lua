local M = {}

local defaults = {
  base = "origin/main",
  picker = {},
}
local config = vim.deepcopy(defaults)

---Configure agentic-flow.nvim.
---@param opts? table
function M.setup(opts)
  opts = opts or {}
  vim.validate("opts", opts, "table")

  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
end

---Return a copy of the active configuration.
---@return table
function M.get_config()
  return vim.deepcopy(config)
end

---Open the changed-files picker.
---@param opts? table
---@return table?
function M.changes(opts)
  return require("agentic-flow.picker").changes(config, opts)
end

return M
