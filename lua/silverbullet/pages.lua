local config = require("silverbullet.config")
local fs = require("silverbullet.client.fs")
local state = require("silverbullet.state")

local M = {}

local function is_markdown(file)
  if not file.name:lower():match("%.md$") then
    return false
  end
  return not file.content_type or file.content_type:find("markdown", 1, true) ~= nil
end

function M.list(space_name, opts)
  opts = opts or {}
  local _, resolved_name = config.space(space_name)
  local cached = state.page_cache[resolved_name]
  local ttl = config.get().cache.page_list_ttl_ms
  if not opts.refresh and cached and (vim.uv.now() - cached.at) < ttl then
    return cached.pages
  end
  local files, err = fs.list(resolved_name)
  if not files then
    return nil, err
  end
  local pages = {}
  for _, file in ipairs(files) do
    if is_markdown(file) then
      table.insert(pages, {
        path = file.name,
        display = file.name:gsub("%.md$", ""),
        meta = file,
      })
    end
  end
  table.sort(pages, function(a, b)
    return a.display:lower() < b.display:lower()
  end)
  state.page_cache[resolved_name] = { at = vim.uv.now(), pages = pages }
  return pages
end

function M.complete(prefix, callback, space_name)
  local pages, err = M.list(space_name)
  if not pages then
    callback({}, err)
    return
  end
  local needle = prefix:lower()
  local matches = {}
  for _, page in ipairs(pages) do
    if page.display:lower():find(needle, 1, true) then
      table.insert(matches, page.display)
    end
  end
  callback(matches)
end

return M
