local log = require("silverbullet.log")
local uri = require("silverbullet.uri")

local M = {}

function M.parse(inner)
  if type(inner) ~= "string" or inner == "" then
    return nil, "empty wiki link"
  end
  local target, alias = inner:match("^([^|]+)|(.+)$")
  target = target or inner
  if target:sub(1, 1) == "$" then
    return { anchor = target, alias = alias }
  end
  local page, heading = target:match("^(.-)#(.+)$")
  page = page or target
  return {
    page = vim.trim(page),
    alias = alias and vim.trim(alias) or nil,
    heading = heading and vim.trim(heading) or nil,
  }
end

function M.at_cursor(line, byte_col)
  local search_from = 1
  while true do
    local start_pos = line:find("[[", search_from, true)
    if not start_pos then
      return nil
    end
    local end_pos = line:find("]]", start_pos + 2, true)
    if not end_pos then
      return nil
    end
    if byte_col + 1 >= start_pos and byte_col + 1 <= end_pos + 1 then
      return M.parse(line:sub(start_pos + 2, end_pos - 1))
    end
    search_from = end_pos + 2
  end
end

local function jump_heading(heading)
  local wanted = heading:lower():gsub("^%s+", ""):gsub("%s+$", "")
  for line_number, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    local found = line:match("^%s*#+%s+(.+)%s*$")
    if found and found:lower() == wanted then
      vim.api.nvim_win_set_cursor(0, { line_number, 0 })
      return true
    end
  end
  return false
end

function M.follow()
  local current = require("silverbullet.state").get(vim.api.nvim_get_current_buf())
  if not current then
    log.error("current buffer is not a SilverBullet page")
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  local link = M.at_cursor(line, cursor[2])
  if not link then
    log.warn("cursor is not on a wiki link")
    return
  end
  if link.anchor then
    log.warn("$anchor links require the optional Runtime API")
    return
  end
  local page = link.page
  if page == "" and link.heading then
    jump_heading(link.heading)
    return
  end
  local path, err = uri.page_path(page)
  if not path then
    log.error(err)
    return
  end
  require("silverbullet.buffer").open(current.space, path)
  if link.heading then
    vim.schedule(function()
      if not jump_heading(link.heading) then
        log.warn(("heading %q was not found"):format(link.heading))
      end
    end)
  end
end

return M
