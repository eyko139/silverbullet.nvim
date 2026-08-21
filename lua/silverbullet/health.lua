local config = require("silverbullet.config")
local fs = require("silverbullet.client.fs")

local M = {}

local function response_check(label, response, err)
  if not response then
    vim.health.error(label .. ": " .. tostring(err))
  elseif response.status >= 200 and response.status < 300 then
    local content_type = response.headers["content-type"] or ""
    if content_type:find("text/html", 1, true) or response.body:match("^%s*<!DOCTYPE html") then
      vim.health.error(label .. " returned HTML; reverse-proxy authentication may be intercepting API requests")
    else
      vim.health.ok(label)
    end
  else
    vim.health.error(fs.describe_error(response, label))
  end
end

function M.check()
  vim.health.start("silverbullet.nvim")
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim 0.10 or newer")
  else
    vim.health.error("Neovim 0.10 or newer is required")
  end

  local executable = config.is_configured() and config.get().transport.executable or "curl"
  if vim.fn.executable(executable) == 1 then
    local version = vim.system({ executable, "--version" }, { text = true }):wait()
    vim.health.ok(vim.split(version.stdout or "", "\n", { plain = true })[1])
  else
    vim.health.error(executable .. " is not available on PATH")
  end

  if not config.is_configured() then
    vim.health.error("Plugin is not configured")
    return
  end
  vim.health.ok("Configuration is valid")

  for name, space in pairs(config.get().spaces) do
    vim.health.start("space: " .. name)
    if space.tls and space.tls.ca_file then
      if vim.fn.filereadable(space.tls.ca_file) == 1 then
        vim.health.ok("Custom CA file is readable")
      else
        vim.health.error("Custom CA file is not readable: " .. space.tls.ca_file)
      end
    end
    local _, token_err = config.resolve_token(space)
    if token_err then
      vim.health.error("Credential provider: " .. token_err)
    else
      vim.health.ok("Credential provider is available")
    end
    local ping, ping_err = fs.ping(name)
    response_check("GET /.ping", ping, ping_err)
    local server_config, server_config_err = fs.server_config(name)
    response_check("GET /.config", server_config, server_config_err)
    local files, list_err = fs.list(name)
    if files then
      vim.health.ok(("GET /.fs returned %d files"):format(#files))
      local read_only = false
      for _, file in ipairs(files) do
        read_only = read_only or file.permission == "ro"
      end
      if read_only then
        vim.health.warn("The listing contains read-only files")
      end
      if files[1] then
        local sample = fs.read(name, files[1].name)
        if sample and sample.meta.etag then
          vim.health.ok("ETag-based conditional writes are available")
        elseif sample then
          vim.health.info("No ETag observed; writes use SilverBullet 2.9 conflict checks")
        end
      end
    else
      vim.health.error("GET /.fs: " .. tostring(list_err))
    end
    if space.runtime.enabled then
      local _, runtime_err = require("silverbullet.client.runtime").eval(name, "true")
      if runtime_err then
        vim.health.error("Runtime API: " .. runtime_err)
      else
        vim.health.ok("Runtime API is available")
      end
    end
  end
end

return M
