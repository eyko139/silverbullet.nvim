if vim.g.loaded_silverbullet_nvim then
  return
end
vim.g.loaded_silverbullet_nvim = true

require("silverbullet.state").init()
require("silverbullet.commands").setup()

local group = vim.api.nvim_create_augroup("SilverBulletNvim", { clear = true })

vim.api.nvim_create_autocmd("BufReadCmd", {
  group = group,
  pattern = "silverbullet://*",
  callback = function(args)
    require("silverbullet.buffer").load(args.buf, vim.api.nvim_buf_get_name(args.buf))
  end,
})

vim.api.nvim_create_autocmd("BufWriteCmd", {
  group = group,
  pattern = "silverbullet://*",
  callback = function(args)
    if not require("silverbullet.buffer").write(args.buf) then
      error("SilverBullet write failed; local changes were preserved")
    end
  end,
})

vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
  group = group,
  pattern = "silverbullet://*",
  callback = function(args)
    local config = require("silverbullet.config")
    if config.is_configured() and config.get().conflict.check_on_focus then
      require("silverbullet.buffer").check_external(args.buf)
    end
  end,
})

vim.api.nvim_create_autocmd("BufWipeout", {
  group = group,
  pattern = "silverbullet://*",
  callback = function(args)
    require("silverbullet.state").remove(args.buf)
  end,
})
