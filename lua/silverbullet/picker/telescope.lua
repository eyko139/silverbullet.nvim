local config = require("silverbullet.config")
local log = require("silverbullet.log")
local pages = require("silverbullet.pages")
local common = require("silverbullet.picker.common")
local search = require("silverbullet.search")

local M = {}

local function telescope_modules()
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local finders = require("telescope.finders")
  local pickers = require("telescope.pickers")
  local previewers = require("telescope.previewers")
  local telescope_config = require("telescope.config").values
  return actions, action_state, finders, pickers, previewers, telescope_config
end

local function previewer(space_name)
  local _, _, _, _, previewers = telescope_modules()
  return previewers.new_buffer_previewer({
    title = "SilverBullet",
    define_preview = function(self, entry)
      local item = entry.value
      local content = item.content
      local err
      if not content then
        content, err = search.read_page(space_name, item.path)
      end
      local lines
      if content then
        lines = vim.split(content, "\n", { plain = true })
        if content:sub(-1) == "\n" then
          table.remove(lines)
        end
      else
        lines = { "Unable to load preview:", tostring(err) }
      end
      if #lines == 0 then
        lines = { "" }
      end
      local bufnr = self.state.bufnr
      if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.bo[bufnr].filetype = "markdown"
      vim.bo[bufnr].modifiable = false
      vim.schedule(function()
        local winid = self.state and self.state.winid
        if item.lnum and winid and vim.api.nvim_win_is_valid(winid) then
          pcall(vim.api.nvim_win_set_cursor, winid, { math.min(item.lnum, #lines), 0 })
        end
      end)
    end,
  })
end

local function pick(space_name, items, title, entry_maker, on_select, extra_opts)
  local actions, action_state, finders, pickers, _, telescope_config = telescope_modules()
  local opts = vim.tbl_deep_extend("force", {}, config.get().picker.telescope or {}, extra_opts or {})
  local picker_previewer = false
  if opts.previewer ~= false then
    picker_previewer = previewer(space_name)
  end

  pickers
    .new(opts, {
      prompt_title = title,
      finder = finders.new_table({
        results = items,
        entry_maker = entry_maker,
      }),
      sorter = telescope_config.generic_sorter(opts),
      previewer = picker_previewer,
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            on_select(selection.value)
          end
        end)
        return true
      end,
    })
    :find()
end

local function result_entry(item)
  return {
    value = item,
    display = common.result_display(item),
    ordinal = item.display .. " " .. item.path .. " " .. item.text,
    path = item.path,
    lnum = item.lnum,
    col = item.col,
  }
end

function M.find(space_name)
  local _, resolved_name = config.space(space_name)
  local items, err = pages.list(resolved_name)
  if not items then
    log.error(err)
    return
  end
  pick(resolved_name, items, ("SilverBullet pages (%s)"):format(resolved_name), function(page)
    return {
      value = page,
      display = page.display,
      ordinal = page.display .. " " .. page.path,
      path = page.path,
    }
  end, function(page)
    require("silverbullet.buffer").open(resolved_name, page.path)
  end)
end

function M.search(space_name, query)
  local _, resolved_name = config.space(space_name)
  local items, err, failures = search.full_text(resolved_name)
  if not items then
    log.error(err)
    return
  end
  local warning = search.failure_message(failures)
  if warning then
    log.warn(warning)
  end
  pick(
    resolved_name,
    items,
    ("Search SilverBullet (%s)"):format(resolved_name),
    result_entry,
    function(item)
      common.open_result(resolved_name, item)
    end,
    query and query ~= "" and { default_text = query } or nil
  )
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
  if #items == 0 then
    log.notify(("No backlinks to %s found"):format(target_path:gsub("%.md$", "")))
    return
  end
  pick(
    resolved_name,
    items,
    ("Backlinks to %s"):format(target_path:gsub("%.md$", "")),
    result_entry,
    function(item)
      common.open_result(resolved_name, item)
    end
  )
end

return M
