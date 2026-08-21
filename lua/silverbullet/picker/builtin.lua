local config = require("silverbullet.config")
local log = require("silverbullet.log")
local pages = require("silverbullet.pages")
local common = require("silverbullet.picker.common")
local search = require("silverbullet.search")

local M = {}

function M.find(space_name)
  local _, resolved_name = config.space(space_name)
  local items, err = pages.list(resolved_name)
  if not items then
    log.error(err)
    return
  end
  vim.ui.select(items, {
    prompt = ("SilverBullet pages (%s):"):format(resolved_name),
    format_item = function(item)
      return item.display
    end,
  }, function(item)
    if item then
      require("silverbullet.buffer").open(resolved_name, item.path)
    end
  end)
end

local function select_results(items, prompt, space_name)
  if #items == 0 then
    log.notify("No SilverBullet matches found")
    return
  end
  vim.ui.select(items, {
    prompt = prompt,
    format_item = common.result_display,
  }, function(item)
    if item then
      common.open_result(space_name, item)
    end
  end)
end

function M.search(space_name, query)
  local _, resolved_name = config.space(space_name)
  local function run(value)
    if not value or value == "" then
      return
    end
    local items, err, failures = search.full_text(resolved_name, value)
    if not items then
      log.error(err)
      return
    end
    local warning = search.failure_message(failures)
    if warning then
      log.warn(warning)
    end
    select_results(items, ("Search SilverBullet (%s):"):format(resolved_name), resolved_name)
  end
  if query and query ~= "" then
    run(query)
  else
    vim.ui.input({ prompt = ("Search SilverBullet (%s): "):format(resolved_name) }, run)
  end
end

function M.backlinks(space_name, target_path)
  local _, resolved_name = config.space(space_name)
  local items, err, failures = search.backlinks(resolved_name, target_path)
  if not items then
    log.error(err)
    return
  end
  local warning = search.failure_message(failures)
  if warning then
    log.warn(warning)
  end
  select_results(items, ("Backlinks to %s:"):format(target_path:gsub("%.md$", "")), resolved_name)
end

return M
