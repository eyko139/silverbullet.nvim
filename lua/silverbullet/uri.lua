local M = {}

local function percent_encode(value)
  return (value:gsub("([^A-Za-z0-9%-%._~])", function(char)
    return ("%%%02X"):format(char:byte())
  end))
end

local function percent_decode(value)
  return (value:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

function M.normalize_path(path)
  if type(path) ~= "string" then
    return nil, "path must be a string"
  end
  path = vim.trim(path):gsub("\\", "/"):gsub("/+", "/")
  if path == "" then
    return nil, "path must not be empty"
  end
  if path:sub(1, 1) == "/" then
    return nil, "absolute paths are not allowed"
  end
  local parts = {}
  for segment in path:gmatch("[^/]+") do
    if segment == ".." then
      return nil, "parent path segments are not allowed"
    end
    if segment ~= "." and segment ~= "" then
      table.insert(parts, segment)
    end
  end
  if #parts == 0 then
    return nil, "path must not be empty"
  end
  return table.concat(parts, "/")
end

function M.page_path(page)
  local path, err = M.normalize_path(page)
  if not path then
    return nil, err
  end
  if not path:lower():match("%.md$") then
    path = path .. ".md"
  end
  return path
end

function M.encode_path(path)
  local normalized, err = M.normalize_path(path)
  if not normalized then
    return nil, err
  end
  local encoded = {}
  for segment in normalized:gmatch("[^/]+") do
    table.insert(encoded, percent_encode(segment))
  end
  return table.concat(encoded, "/")
end

function M.buffer_uri(space, path)
  local encoded, err = M.encode_path(path)
  if not encoded then
    return nil, err
  end
  return ("silverbullet://%s/%s"):format(percent_encode(space), encoded)
end

function M.parse_buffer_uri(value)
  local authority, path = value:match("^silverbullet://([^/]+)/(.+)$")
  if not authority then
    return nil, "invalid SilverBullet buffer URI"
  end
  local decoded = {}
  for segment in path:gmatch("[^/]+") do
    table.insert(decoded, percent_decode(segment))
  end
  local normalized, err = M.normalize_path(table.concat(decoded, "/"))
  if not normalized then
    return nil, err
  end
  return {
    space = percent_decode(authority),
    path = normalized,
  }
end

function M.web_url(base_url, path)
  local page = path:gsub("%.md$", "")
  local encoded, err = M.encode_path(page)
  if not encoded then
    return nil, err
  end
  return base_url:gsub("/+$", "") .. "/" .. encoded
end

return M
