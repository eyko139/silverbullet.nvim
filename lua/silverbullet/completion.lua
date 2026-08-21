local pages = require("silverbullet.pages")
local state = require("silverbullet.state")

local M = {}

function M.omnifunc(findstart, base)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local before = line:sub(1, col)
    local start = before:match(".*()%[%[[^%]]*$")
    if not start then
      return -2
    end
    return start + 1
  end
  local buffer_state = state.get(vim.api.nvim_get_current_buf())
  local result = {}
  local completion_err
  pages.complete(base, function(matches, err)
    result = matches
    completion_err = err
  end, buffer_state and buffer_state.space or nil)
  if completion_err then
    vim.schedule(function()
      require("silverbullet.log").error("page completion failed: " .. completion_err)
    end)
  end
  return result
end

return M
