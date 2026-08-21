local config = require("silverbullet.config")
local log = require("silverbullet.log")
local pages = require("silverbullet.pages")

local M = {}

function M.find(space_name)
  local _, resolved_name = config.space(space_name)
  local items, err = pages.list(resolved_name)
  if not items then
    log.error(err)
    return
  end
  vim.ui.select(items, {
    prompt = ("SilverBullet pages (%s):"):format(resolved_name),
    format_item = function(item)
      return item.display
    end,
  }, function(item)
    if item then
      require("silverbullet.buffer").open(resolved_name, item.path)
    end
  end)
end

return M
