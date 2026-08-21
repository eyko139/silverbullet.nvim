local M = {}

function M.schedule(callback)
  vim.schedule(callback)
end

return M
