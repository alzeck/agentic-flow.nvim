local M = {}

---Open a Snacks picker containing files changed from the configured base ref.
---@param config table
---@param opts? table
---@return table?
function M.changes(config, opts)
  opts = opts or {}

  vim.validate("config", config, "table")
  vim.validate("opts", opts, "table")
  vim.validate("config.base", config.base, "string")
  vim.validate("config.picker", config.picker, "table")
  vim.validate("opts.base", opts.base, "string", true)
  vim.validate("opts.picker", opts.picker, "table", true)

  local base = opts.base or config.base
  local ok, git_diff = pcall(function()
    return require("snacks").picker.git_diff
  end)

  if not ok or type(git_diff) ~= "function" then
    vim.notify(
      "agentic-flow.nvim requires snacks.nvim with its picker enabled",
      vim.log.levels.ERROR,
      { title = "agentic-flow.nvim" }
    )
    return nil
  end

  local picker_opts = vim.tbl_deep_extend(
    "force",
    {
      title = ("Changes vs %s"):format(base),
    },
    config.picker,
    opts.picker or {},
    {
      base = base,
      group = true,
    }
  )

  return git_diff(picker_opts)
end

return M
