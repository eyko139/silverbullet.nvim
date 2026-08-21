local config = require("silverbullet.config")
local transport = require("silverbullet.transport.curl")
local uri = require("silverbullet.uri")

local M = {}

local function request(space_name, method, endpoint, opts)
  local space = config.space(space_name)
  opts = opts or {}
  local response, err = transport.request(space, {
    method = method,
    url = space.url .. endpoint,
    headers = opts.headers,
    body = opts.body,
  })
  if not response then
    return nil, err
  end
  return response
end

local function metadata(headers, fallback)
  fallback = fallback or {}
  return {
    name = fallback.name,
    created = tonumber(headers["x-created"] or fallback.created),
    last_modified = tonumber(headers["x-last-modified"] or fallback.lastModified),
    content_type = headers["content-type"] or fallback.contentType,
    size = tonumber(headers["x-content-length"] or fallback.size),
    permission = headers["x-permission"] or fallback.perm,
    etag = headers.etag,
    raw = fallback,
  }
end

function M.describe_error(response, operation)
  local status = response.status
  if status >= 300 and status < 400 then
    return ("%s was redirected; reverse-proxy authentication may be intercepting SilverBullet API requests"):format(operation)
  elseif status == 401 then
    return operation .. " failed: invalid or missing SilverBullet authentication"
  elseif status == 403 then
    return operation .. " failed: access denied or the page is read-only"
  elseif status == 404 then
    return operation .. " failed: page not found"
  elseif status == 412 then
    return operation .. " failed: the remote page changed"
  elseif status >= 500 then
    return ("%s failed: SilverBullet returned HTTP %d"):format(operation, status)
  end
  local content_type = response.headers["content-type"] or ""
  if content_type:find("text/html", 1, true) or response.body:match("^%s*<!DOCTYPE html") then
    return operation .. " returned HTML; a reverse-proxy login page may be intercepting API requests"
  end
  return ("%s failed with HTTP %d"):format(operation, status)
end

function M.ping(space_name)
  return request(space_name, "GET", "/.ping")
end

function M.server_config(space_name)
  return request(space_name, "GET", "/.config")
end

function M.list(space_name)
  local response, err = request(space_name, "GET", "/.fs")
  if not response then
    return nil, err
  end
  if response.status ~= 200 then
    return nil, M.describe_error(response, "listing pages"), response
  end
  local content_type = response.headers["content-type"] or ""
  if content_type:find("text/html", 1, true) or response.body:match("^%s*<!DOCTYPE html") then
    return nil,
      "listing pages returned HTML; a reverse-proxy login page may be intercepting API requests",
      response
  end
  local ok, decoded = pcall(vim.json.decode, response.body)
  if not ok or type(decoded) ~= "table" then
    return nil, "listing pages returned invalid JSON", response
  end
  local files = {}
  local source = decoded.files or decoded
  for _, item in ipairs(source) do
    if type(item) == "string" then
      table.insert(files, { name = item })
    elseif type(item) == "table" and item.name then
      local meta = metadata({}, item)
      meta.name = item.name
      table.insert(files, meta)
    end
  end
  return files, nil, response
end

function M.read(space_name, path)
  local encoded, encode_err = uri.encode_path(path)
  if not encoded then
    return nil, encode_err
  end
  local response, err = request(space_name, "GET", "/.fs/" .. encoded)
  if not response then
    return nil, err
  end
  if response.status ~= 200 then
    return nil, M.describe_error(response, "reading page"), response
  end
  return {
    content = response.body,
    meta = metadata(response.headers, { name = path }),
  }, nil, response
end

function M.write(space_name, path, content, precondition)
  local encoded, encode_err = uri.encode_path(path)
  if not encoded then
    return nil, encode_err
  end
  local headers = { ["Content-Type"] = "text/markdown; charset=utf-8" }
  if precondition and precondition.etag then
    headers["If-Match"] = precondition.etag
  elseif precondition and precondition.create then
    headers["If-None-Match"] = "*"
  end
  local response, err = request(space_name, "PUT", "/.fs/" .. encoded, {
    headers = headers,
    body = content,
  })
  if not response then
    return nil, err
  end
  if response.status < 200 or response.status >= 300 then
    return nil, M.describe_error(response, "writing page"), response
  end
  return metadata(response.headers, { name = path }), nil, response
end

function M.delete(space_name, path)
  local encoded, encode_err = uri.encode_path(path)
  if not encoded then
    return nil, encode_err
  end
  local response, err = request(space_name, "DELETE", "/.fs/" .. encoded)
  if not response then
    return nil, err
  end
  if response.status < 200 or response.status >= 300 then
    return nil, M.describe_error(response, "deleting page"), response
  end
  return true, nil, response
end

return M
