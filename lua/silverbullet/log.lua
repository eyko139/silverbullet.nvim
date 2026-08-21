local M = {}

local function redact(value)
  if type(value) ~= "string" then
    return value
  end
  value = value:gsub("[Aa]uthorization:%s*[^%s\r\n]+%s+[^%s\r\n]+", "Authorization: <redacted>")
  value = value:gsub("[Bb]earer%s+[%w%._~%+/%-]+=*", "Bearer <redacted>")
  return value
end

function M.redact(value)
  return redact(value)
end

function M.notify(message, level)
  vim.notify(redact(message), level or vim.log.levels.INFO, { title = "silverbullet.nvim" })
end

function M.error(message)
  M.notify(message, vim.log.levels.ERROR)
end

function M.warn(message)
  M.notify(message, vim.log.levels.WARN)
end

return M
