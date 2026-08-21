local config = require("silverbullet.config")
local transport = require("silverbullet.transport.curl")

local M = {}

function M.literal(value)
  assert(type(value) == "string", "runtime.literal expects a string")
  return '"' .. value:gsub("[\\\"\n\r\t\b\f%z\1-\31]", function(char)
    local escapes = {
      ["\\"] = "\\\\",
      ['"'] = '\\"',
      ["\n"] = "\\n",
      ["\r"] = "\\r",
      ["\t"] = "\\t",
      ["\b"] = "\\b",
      ["\f"] = "\\f",
    }
    return escapes[char] or ("\\%03d"):format(char:byte())
  end) .. '"'
end

function M.eval(space_name, expression)
  local space = config.space(space_name)
  if not space.runtime.enabled then
    return nil, "Runtime API is disabled for this space"
  end
  local response, err = transport.request(space, {
    method = "POST",
    url = space.url .. "/.runtime/lua",
    headers = { ["Content-Type"] = "text/plain; charset=utf-8" },
    body = expression,
  })
  if not response then
    return nil, err
  end
  if response.status < 200 or response.status >= 300 then
    return nil, ("Runtime API returned HTTP %d"):format(response.status)
  end
  local ok, decoded = pcall(vim.json.decode, response.body)
  return ok and decoded or response.body
end

return M
