local M = {
  buffers = {},
  page_cache = {},
  content_cache = {},
  search_indexes = {},
  search_index_dirty = {},
  session_id = nil,
}

function M.init()
  if M.session_id then
    return
  end
  math.randomseed(os.time() + vim.fn.getpid())
  M.session_id = ("%x-%x-%x"):format(os.time(), vim.fn.getpid(), math.random(0, 0xffffff))
end

function M.get(buf)
  return M.buffers[buf]
end

function M.set(buf, value)
  M.buffers[buf] = value
end

function M.remove(buf)
  M.buffers[buf] = nil
end

function M.invalidate_pages(space)
  M.page_cache[space] = nil
end

function M.invalidate_content(space, path)
  if path and M.content_cache[space] then
    M.content_cache[space][path] = nil
  else
    M.content_cache[space] = nil
  end
end

function M.invalidate_search_index(space, path)
  if not path then
    M.search_indexes[space] = nil
    M.search_index_dirty[space] = nil
    return
  end
  M.search_index_dirty[space] = M.search_index_dirty[space] or {}
  M.search_index_dirty[space][path] = true
end

return M
