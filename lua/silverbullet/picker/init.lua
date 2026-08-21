local M = {}

function M.find(space_name)
  local provider = require("silverbullet.config").get().picker.provider
  if provider ~= "auto" and provider ~= "builtin" then
    error(("unsupported picker provider %q; use 'auto' or 'builtin'"):format(provider))
  end
  return require("silverbullet.picker.builtin").find(space_name)
end

return M
