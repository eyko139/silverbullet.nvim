local M = {}

function M.open_result(space_name, item)
  require("silverbullet.buffer").open(space_name, item.path)
  if item.lnum then
    local line_count = vim.api.nvim_buf_line_count(0)
    pcall(vim.api.nvim_win_set_cursor, 0, { math.min(item.lnum, line_count), math.max(0, (item.col or 1) - 1) })
  end
end

function M.result_display(item)
  return ("%s:%d: %s"):format(item.display, item.lnum, vim.trim(item.text))
end

return M
