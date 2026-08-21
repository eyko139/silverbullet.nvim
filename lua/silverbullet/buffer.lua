local config = require("silverbullet.config")
local conflict = require("silverbullet.conflict")
local fs = require("silverbullet.client.fs")
local log = require("silverbullet.log")
local state = require("silverbullet.state")
local uri = require("silverbullet.uri")

local M = {}

local function hash(content)
  return vim.fn.sha256(content)
end

local function content_lines(content)
  local endofline = content:sub(-1) == "\n"
  local lines = vim.split(content, "\n", { plain = true })
  if endofline then
    table.remove(lines)
  end
  if #lines == 0 then
    lines = { "" }
  end
  return lines, endofline
end

local function serialize(buf)
  local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  if vim.bo[buf].endofline then
    content = content .. "\n"
  end
  return content
end

local function configure(buf)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].omnifunc = "v:lua.require'silverbullet.completion'.omnifunc"
end

local function populate(buf, content, meta, exists)
  local lines, endofline = content_lines(content)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].endofline = endofline
  vim.bo[buf].modified = false
  vim.bo[buf].readonly = meta.permission == "ro"
  vim.bo[buf].modifiable = meta.permission ~= "ro"
  local previous = state.get(buf)
  state.set(buf, {
    space = previous and previous.space,
    path = previous and previous.path,
    base_content = content,
    base_hash = hash(content),
    etag = meta.etag,
    last_modified = meta.last_modified,
    permission = meta.permission or "rw",
    writing = false,
    exists = exists,
    last_check = vim.uv.now(),
  })
end

function M.load(buf, name)
  local previous_cursor = vim.api.nvim_buf_get_mark(buf, '"')
  local parsed, parse_err = uri.parse_buffer_uri(name or vim.api.nvim_buf_get_name(buf))
  if not parsed then
    log.error(parse_err)
    return
  end
  local ok, space_err = pcall(config.space, parsed.space)
  if not ok then
    log.error(space_err)
    return
  end
  configure(buf)
  state.set(buf, { space = parsed.space, path = parsed.path, writing = false })
  local result, err, response = fs.read(parsed.space, parsed.path)
  if not result then
    if response and response.status == 404 then
      populate(buf, "", { permission = "rw" }, false)
      return
    end
    log.error(err)
    return
  end
  populate(buf, result.content, result.meta, true)
  if previous_cursor[1] > 0 and vim.api.nvim_get_current_buf() == buf then
    pcall(vim.api.nvim_win_set_cursor, 0, previous_cursor)
  end
end

function M.open(space_name, page)
  local _, resolved_name = config.space(space_name)
  local path, path_err = uri.page_path(page)
  if not path then
    log.error(path_err)
    return
  end
  local name = assert(uri.buffer_uri(resolved_name, path))
  vim.cmd.edit(vim.fn.fnameescape(name))
end

function M.reload(buf, discard_changes)
  buf = buf or vim.api.nvim_get_current_buf()
  local buffer_state = state.get(buf)
  if not buffer_state then
    log.error("current buffer is not a SilverBullet page")
    return
  end
  if vim.bo[buf].modified and not discard_changes then
    log.warn("buffer has local changes; use :SilverBulletReload! to discard them")
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local result, err = fs.read(buffer_state.space, buffer_state.path)
  if not result then
    log.error(err)
    return
  end
  populate(buf, result.content, result.meta, true)
  pcall(vim.api.nvim_win_set_cursor, 0, cursor)
end

function M.write(buf, opts)
  opts = opts or {}
  buf = buf or vim.api.nvim_get_current_buf()
  local buffer_state = state.get(buf)
  if not buffer_state then
    log.error("current buffer is not a SilverBullet page")
    return false
  end
  if buffer_state.writing then
    log.warn("a write is already in progress")
    return false
  end
  if buffer_state.permission == "ro" then
    log.error("this SilverBullet page is read-only")
    return false
  end

  buffer_state.writing = true
  local content = serialize(buf)
  local precondition
  if not opts.force then
    if not buffer_state.exists then
      local remote, _, response = fs.read(buffer_state.space, buffer_state.path)
      if remote then
        buffer_state.writing = false
        conflict.handle(buf, remote.content)
        log.error("write refused because the page was created remotely")
        return false
      elseif not response or response.status ~= 404 then
        buffer_state.writing = false
        log.error("could not verify that the new page is still absent")
        return false
      end
      precondition = { create = true }
    elseif buffer_state.etag then
      precondition = { etag = buffer_state.etag }
    elseif config.get().conflict.check_before_write then
      local remote, read_err = fs.read(buffer_state.space, buffer_state.path)
      if not remote then
        buffer_state.writing = false
        log.error(read_err)
        return false
      end
      if hash(remote.content) ~= buffer_state.base_hash then
        buffer_state.writing = false
        conflict.handle(buf, remote.content)
        log.error("write refused because the remote page changed")
        return false
      end
    end
  end

  local meta, err, response = fs.write(buffer_state.space, buffer_state.path, content, precondition)
  buffer_state.writing = false
  if not meta then
    if response and response.status == 412 then
      conflict.fetch_and_handle(buf, buffer_state)
    end
    log.error(err)
    return false
  end
  buffer_state.base_content = content
  buffer_state.base_hash = hash(content)
  buffer_state.etag = meta.etag
  buffer_state.last_modified = meta.last_modified
  buffer_state.exists = true
  buffer_state.last_check = vim.uv.now()
  if not buffer_state.etag then
    local refreshed = fs.read(buffer_state.space, buffer_state.path)
    if refreshed then
      buffer_state.etag = refreshed.meta.etag
      buffer_state.last_modified = refreshed.meta.last_modified
    end
  end
  vim.bo[buf].modified = false
  state.invalidate_pages(buffer_state.space)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "SilverBulletWritePost",
    modeline = false,
    data = { buf = buf, space = buffer_state.space, path = buffer_state.path },
  })
  return true
end

function M.delete(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local buffer_state = state.get(buf)
  if not buffer_state then
    log.error("current buffer is not a SilverBullet page")
    return
  end
  vim.ui.select({ "Delete", "Cancel" }, {
    prompt = ("Delete %s?"):format(buffer_state.path),
  }, function(choice)
    if choice ~= "Delete" then
      return
    end
    local ok, err = fs.delete(buffer_state.space, buffer_state.path)
    if not ok then
      log.error(err)
      return
    end
    state.invalidate_pages(buffer_state.space)
    state.remove(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end

function M.check_external(buf)
  local buffer_state = state.get(buf)
  if not buffer_state or buffer_state.writing or not buffer_state.exists then
    return
  end
  if vim.uv.now() - (buffer_state.last_check or 0) < 1000 then
    return
  end
  buffer_state.last_check = vim.uv.now()
  local remote = fs.read(buffer_state.space, buffer_state.path)
  if not remote or hash(remote.content) == buffer_state.base_hash then
    return
  end
  if vim.bo[buf].modified then
    log.warn("SilverBullet page changed remotely; local changes were left untouched")
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  populate(buf, remote.content, remote.meta, true)
  pcall(vim.api.nvim_win_set_cursor, 0, cursor)
  log.notify("Reloaded SilverBullet page after a remote change")
end

return M
