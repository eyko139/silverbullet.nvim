local config = require("silverbullet.config")
local log = require("silverbullet.log")
local state = require("silverbullet.state")
local uri = require("silverbullet.uri")

local M = {}
local registered = false

local function configured(callback)
  return function(...)
    if not config.is_configured() then
      log.error("silverbullet.nvim is not configured; call require('silverbullet').setup()")
      return
    end
    local ok, err = pcall(callback, ...)
    if not ok then
      log.error(err)
    end
  end
end

local function current_state()
  local value = state.get(vim.api.nvim_get_current_buf())
  if not value then
    error("current buffer is not a SilverBullet page")
  end
  return value
end

local function complete_space()
  if not config.is_configured() then
    return {}
  end
  local names = vim.tbl_keys(config.get().spaces)
  table.sort(names)
  return names
end

function M.setup()
  if registered then
    return
  end
  registered = true

  vim.api.nvim_create_user_command("SilverBulletHealth", function()
    vim.cmd("checkhealth silverbullet")
  end, {})
  vim.api.nvim_create_user_command("SilverBulletSetToken", configured(function(opts)
    local _, space_name = config.space(opts.args ~= "" and opts.args or nil)
    local token = vim.fn.inputsecret(("SilverBullet token (%s): "):format(space_name))
    if token == "" then
      log.warn("SilverBullet token was not changed")
      return
    end
    config.set_session_token(space_name, token)
    log.notify(("Session token set for %s"):format(space_name))
  end), { nargs = "?", complete = complete_space })
  vim.api.nvim_create_user_command("SilverBulletFind", configured(function()
    require("silverbullet.picker").find()
  end), {})
  vim.api.nvim_create_user_command("SilverBulletSearch", configured(function(opts)
    require("silverbullet.picker").search(nil, opts.args)
  end), { nargs = "*" })
  vim.api.nvim_create_user_command("SilverBulletOpen", configured(function(opts)
    require("silverbullet.buffer").open(nil, opts.args)
  end), { nargs = "+" })
  vim.api.nvim_create_user_command("SilverBulletNew", configured(function(opts)
    require("silverbullet.buffer").open(nil, opts.args)
  end), { nargs = "+" })
  vim.api.nvim_create_user_command("SilverBulletReload", configured(function(opts)
    require("silverbullet.buffer").reload(nil, opts.bang)
  end), { bang = true })
  vim.api.nvim_create_user_command("SilverBulletDelete", configured(function()
    require("silverbullet.buffer").delete()
  end), {})
  vim.api.nvim_create_user_command("SilverBulletFollowLink", configured(function()
    require("silverbullet.links").follow()
  end), {})
  vim.api.nvim_create_user_command("SilverBulletBacklinks", configured(function()
    local value = current_state()
    require("silverbullet.picker").backlinks(value.space, value.path)
  end), {})
  vim.api.nvim_create_user_command("SilverBulletOpenWeb", configured(function()
    local value = current_state()
    local space = config.space(value.space)
    local url, err = uri.web_url(space.url, value.path)
    if not url then
      error(err)
    end
    vim.ui.open(url)
  end), {})
  vim.api.nvim_create_user_command("SilverBulletHome", configured(function()
    require("silverbullet.buffer").open(nil, "index")
  end), {})

  vim.keymap.set("n", "<Plug>(SilverBulletFind)", "<Cmd>SilverBulletFind<CR>")
  vim.keymap.set("n", "<Plug>(SilverBulletSetToken)", "<Cmd>SilverBulletSetToken<CR>")
  vim.keymap.set("n", "<Plug>(SilverBulletSearch)", "<Cmd>SilverBulletSearch<CR>")
  vim.keymap.set("n", "<Plug>(SilverBulletFollowLink)", "<Cmd>SilverBulletFollowLink<CR>")
  vim.keymap.set("n", "<Plug>(SilverBulletBacklinks)", "<Cmd>SilverBulletBacklinks<CR>")
  vim.keymap.set("n", "<Plug>(SilverBulletOpenWeb)", "<Cmd>SilverBulletOpenWeb<CR>")
end

return M
