local M = {
  buffers = {},
  page_cache = {},
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

return M
