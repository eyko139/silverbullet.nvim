local config = require("silverbullet.config")
local fs = require("silverbullet.client.fs")
local links = require("silverbullet.links")
local pages = require("silverbullet.pages")
local state = require("silverbullet.state")
local uri = require("silverbullet.uri")

local M = {}

local function cache_for(space)
  state.content_cache[space] = state.content_cache[space] or {}
  return state.content_cache[space]
end

local function index_for(space)
  state.search_indexes[space] = state.search_indexes[space] or {
    documents = {},
    lines = {},
    incoming = {},
  }
  return state.search_indexes[space]
end

local function metadata_changed(document, page)
  if not document then
    return true
  end
  local old = document.list_meta or {}
  local new = page.meta or {}
  local comparable = false
  if old.last_modified ~= nil or new.last_modified ~= nil then
    comparable = true
    if old.last_modified ~= new.last_modified then
      return true
    end
  end
  if old.size ~= nil or new.size ~= nil then
    comparable = true
    if old.size ~= new.size then
      return true
    end
  end
  if comparable then
    return false
  end
  return (vim.uv.now() - (document.indexed_at or 0)) >= config.get().cache.page_content_ttl_ms
end

local function make_result(document, line, line_number, column)
  return {
    path = document.path,
    display = document.display,
    content = document.content,
    lnum = line_number,
    col = column or 1,
    text = line,
  }
end

local function build_document(page, content, meta)
  local document = {
    path = page.path,
    display = page.display,
    content = content,
    meta = vim.tbl_deep_extend("force", {}, page.meta or {}, meta or {}),
    list_meta = vim.deepcopy(page.meta or {}),
    indexed_at = vim.uv.now(),
    lines = vim.split(content, "\n", { plain = true }),
    outgoing = {},
  }
  for line_number, line in ipairs(document.lines) do
    for _, link in ipairs(links.extract(line)) do
      if link.page and link.page ~= "" then
        local target = uri.page_path(link.page)
        if target then
          table.insert(document.outgoing, {
            target = target:lower(),
            lnum = line_number,
            col = link.start_col,
            text = line,
          })
        end
      end
    end
  end
  return document
end

local function rebuild_derived(index)
  index.lines = {}
  index.incoming = {}
  for _, document in pairs(index.documents) do
    for line_number, line in ipairs(document.lines) do
      if line ~= "" then
        local entry = make_result(document, line, line_number, 1)
        table.insert(index.lines, entry)
      end
    end
    for _, outgoing in ipairs(document.outgoing) do
      index.incoming[outgoing.target] = index.incoming[outgoing.target] or {}
      table.insert(
        index.incoming[outgoing.target],
        make_result(document, outgoing.text, outgoing.lnum, outgoing.col)
      )
    end
  end
  local function result_order(a, b)
    if a.path == b.path then
      return a.lnum < b.lnum
    end
    return a.path:lower() < b.path:lower()
  end
  table.sort(index.lines, result_order)
  for _, entries in pairs(index.incoming) do
    table.sort(entries, result_order)
  end
end

function M.read_page(space_name, path, opts)
  opts = opts or {}
  local _, resolved_name = config.space(space_name)
  local dirty = state.search_index_dirty[resolved_name]
  local index = state.search_indexes[resolved_name]
  local indexed = index and index.documents[path]
  if not opts.refresh and indexed and not (dirty and dirty[path]) then
    return indexed.content, indexed.meta
  end
  local cache = cache_for(resolved_name)
  local cached = cache[path]
  local ttl = config.get().cache.page_content_ttl_ms
  if not opts.refresh and cached and (vim.uv.now() - cached.at) < ttl then
    return cached.content, cached.meta
  end
  local result, err = fs.read(resolved_name, path)
  if not result then
    return nil, err
  end
  cache[path] = {
    at = vim.uv.now(),
    content = result.content,
    meta = result.meta,
  }
  return result.content, result.meta
end

function M.refresh(space_name, opts)
  opts = opts or {}
  local _, resolved_name = config.space(space_name)
  local page_items, list_err = pages.list(resolved_name, { refresh = opts.refresh_listing or opts.refresh })
  if not page_items then
    return nil, list_err
  end

  local index = index_for(resolved_name)
  local dirty = state.search_index_dirty[resolved_name] or {}
  local present = {}
  local failures = {}
  local changed = false

  for _, page in ipairs(page_items) do
    present[page.path] = true
    local current = index.documents[page.path]
    if opts.refresh or dirty[page.path] or metadata_changed(current, page) then
      local content, read_meta_or_err = M.read_page(resolved_name, page.path, { refresh = true })
      if content then
        index.documents[page.path] = build_document(page, content, read_meta_or_err)
        dirty[page.path] = nil
        changed = true
      else
        table.insert(failures, {
          path = page.path,
          error = read_meta_or_err and read_meta_or_err ~= "" and read_meta_or_err or "unknown read failure",
        })
      end
    end
  end

  for path in pairs(index.documents) do
    if not present[path] then
      index.documents[path] = nil
      dirty[path] = nil
      state.invalidate_content(resolved_name, path)
      changed = true
    end
  end

  state.search_index_dirty[resolved_name] = dirty
  if changed or not index.built then
    rebuild_derived(index)
    index.built = true
  end

  if vim.tbl_isempty(index.documents) and #failures > 0 then
    local first = failures[1]
    return nil, ("could not index any pages; first failure was %s: %s"):format(first.path, first.error)
  end
  return index, nil, failures
end

function M.documents(space_name, opts)
  local index, err, failures = M.refresh(space_name, opts)
  if not index then
    return nil, err
  end
  local documents = {}
  for _, document in pairs(index.documents) do
    table.insert(documents, document)
  end
  table.sort(documents, function(a, b)
    return a.path:lower() < b.path:lower()
  end)
  return documents, nil, failures
end

function M.full_text(space_name, query, opts)
  local index, err, failures = M.refresh(space_name, opts)
  if not index then
    return nil, err
  end
  local needle = query and query:lower() or nil
  if needle == "" then
    needle = nil
  end
  if not needle then
    return vim.deepcopy(index.lines), nil, failures
  end

  local matches = {}
  for _, entry in ipairs(index.lines) do
    local column = entry.text:lower():find(needle, 1, true)
    if column then
      local match = vim.deepcopy(entry)
      match.col = column
      table.insert(matches, match)
    end
  end
  return matches, nil, failures
end

function M.backlinks(space_name, target_path, opts)
  local normalized_target, path_err = uri.page_path(target_path)
  if not normalized_target then
    return nil, path_err
  end
  local index, err, failures = M.refresh(space_name, opts)
  if not index then
    return nil, err
  end
  local matches = {}
  for _, entry in ipairs(index.incoming[normalized_target:lower()] or {}) do
    if entry.path:lower() ~= normalized_target:lower() then
      table.insert(matches, vim.deepcopy(entry))
    end
  end
  return matches, nil, failures
end

function M.failure_message(failures)
  if not failures or #failures == 0 then
    return nil
  end
  local first = failures[1]
  local message = ("Skipped %d page%s while indexing; %s: %s"):format(
    #failures,
    #failures == 1 and "" or "s",
    first.path,
    first.error
  )
  if #failures > 1 then
    message = message .. (" (and %d more)"):format(#failures - 1)
  end
  return message
end

return M
