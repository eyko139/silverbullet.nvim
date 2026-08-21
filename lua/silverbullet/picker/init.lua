local M = {}

function M.resolve_provider(provider)
  if provider == "builtin" then
    return "builtin"
  end
  if provider == "telescope" then
    if pcall(require, "telescope.pickers") then
      return "telescope"
    end
    error("picker provider 'telescope' requires nvim-telescope/telescope.nvim")
  end
  if provider == "auto" then
    return pcall(require, "telescope.pickers") and "telescope" or "builtin"
  end
  error(("unsupported picker provider %q; use 'auto', 'telescope', or 'builtin'"):format(provider))
end

function M.find(space_name)
  local provider = M.resolve_provider(require("silverbullet.config").get().picker.provider)
  return require("silverbullet.picker." .. provider).find(space_name)
end

function M.search(space_name, query)
  local provider = M.resolve_provider(require("silverbullet.config").get().picker.provider)
  return require("silverbullet.picker." .. provider).search(space_name, query)
end

function M.backlinks(space_name, target_path)
  local provider = M.resolve_provider(require("silverbullet.config").get().picker.provider)
  return require("silverbullet.picker." .. provider).backlinks(space_name, target_path)
end

return M
