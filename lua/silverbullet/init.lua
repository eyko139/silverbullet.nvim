local M = {}

function M.setup(opts)
  require("silverbullet.state").init()
  require("silverbullet.config").setup(opts)
  require("silverbullet.commands").setup()
end

function M.open(page, space)
  return require("silverbullet.buffer").open(space, page)
end

function M.find(space)
  return require("silverbullet.picker").find(space)
end

return M
