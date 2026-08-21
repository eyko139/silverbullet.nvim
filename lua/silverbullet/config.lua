local M = {}

local defaults = {
  default_space = nil,
  spaces = {},
  transport = {
    timeout_ms = 10000,
    executable = "curl",
  },
  cache = {
    page_list_ttl_ms = 5000,
    page_content_ttl_ms = 30000,
  },
  conflict = {
    check_on_focus = true,
    check_before_write = true,
  },
  picker = {
    provider = "auto",
    telescope = {},
  },
}

local config
local session_tokens = {}

local function validate_space(name, space)
  if type(space) ~= "table" then
    error(("spaces.%s must be a table"):format(name))
  end
  if type(space.url) ~= "string" or space.url == "" then
    error(("spaces.%s.url must be a non-empty string"):format(name))
  end
  space.url = space.url:gsub("/+$", "")
  if space.auth ~= nil and type(space.auth) ~= "table" then
    error(("spaces.%s.auth must be a table"):format(name))
  end
  if space.auth and space.auth.token ~= nil and type(space.auth.token) ~= "function" then
    error(("spaces.%s.auth.token must be a function; use token_env for environment credentials"):format(name))
  end
  space.runtime = vim.tbl_deep_extend("force", { enabled = false }, space.runtime or {})
end

function M.setup(opts)
  opts = opts or {}
  session_tokens = {}
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  if type(config.spaces) ~= "table" or vim.tbl_isempty(config.spaces) then
    error("silverbullet.nvim requires at least one configured space")
  end
  for name, space in pairs(config.spaces) do
    validate_space(name, space)
  end
  if config.default_space == nil then
    config.default_space = next(config.spaces)
  end
  if config.spaces[config.default_space] == nil then
    error(("default_space %q is not present in spaces"):format(config.default_space))
  end
  if type(config.transport.timeout_ms) ~= "number" or config.transport.timeout_ms <= 0 then
    error("transport.timeout_ms must be a positive number")
  end
  return config
end

function M.get()
  if not config then
    error("silverbullet.nvim is not configured; call require('silverbullet').setup()")
  end
  return config
end

function M.space(name)
  local current = M.get()
  name = name or current.default_space
  local space = current.spaces[name]
  if not space then
    error(("unknown SilverBullet space %q"):format(name))
  end
  return space, name
end

local function command_token(command)
  if type(command) ~= "table" or #command == 0 then
    return nil, "auth.command must be a non-empty argv table"
  end
  local result = vim.system(command, { text = true }):wait()
  if result.code ~= 0 then
    return nil, ("credential command failed: %s"):format(result.stderr or ("exit " .. result.code))
  end
  return vim.trim(result.stdout or "")
end

function M.resolve_token(space)
  if session_tokens[space] then
    return session_tokens[space]
  end
  local auth = space.auth
  if not auth then
    return nil
  end
  local token
  local err
  if auth.token_env then
    token = vim.env[auth.token_env]
    if not token or token == "" then
      return nil, ("environment variable %s is not set"):format(auth.token_env)
    end
  elseif type(auth.token) == "function" then
    local ok, value = pcall(auth.token)
    if not ok then
      return nil, "credential callback failed: " .. tostring(value)
    end
    token = value
  elseif auth.command then
    token, err = command_token(auth.command)
    if err then
      return nil, err
    end
  end
  if token ~= nil and (type(token) ~= "string" or token == "") then
    return nil, "credential provider returned an empty or non-string token"
  end
  return token
end

function M.set_session_token(space_name, token)
  local space, resolved_name = M.space(space_name)
  if type(token) ~= "string" or token == "" then
    error("session token must be a non-empty string")
  end
  session_tokens[space] = token
  return resolved_name
end

function M.clear_session_token(space_name)
  local space = M.space(space_name)
  session_tokens[space] = nil
end

function M.is_configured()
  return config ~= nil
end

return M
