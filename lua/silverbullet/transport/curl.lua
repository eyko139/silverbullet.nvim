local config = require("silverbullet.config")
local log = require("silverbullet.log")
local state = require("silverbullet.state")

local M = {}

local function temp_file()
  local path = vim.fn.tempname()
  local fd, err = vim.uv.fs_open(path, "w", 384)
  if not fd then
    error(("cannot create temporary file: %s"):format(err))
  end
  vim.uv.fs_close(fd)
  return path
end

local function write_file(path, content)
  local fd, err = vim.uv.fs_open(path, "w", 384)
  if not fd then
    return nil, err
  end
  local ok, write_err = vim.uv.fs_write(fd, content, 0)
  vim.uv.fs_close(fd)
  if not ok then
    return nil, write_err
  end
  return true
end

local function read_file(path)
  local fd = vim.uv.fs_open(path, "r", 384)
  if not fd then
    return ""
  end
  local stat = vim.uv.fs_fstat(fd)
  local content = stat and vim.uv.fs_read(fd, stat.size, 0) or ""
  vim.uv.fs_close(fd)
  return content or ""
end

local function parse_headers(raw)
  local headers = {}
  local status = 0
  for block in raw:gmatch("(HTTP/[^\r\n]+.-)\r?\n\r?\n") do
    local status_line = block:match("([^\r\n]+)")
    status = tonumber(status_line and status_line:match("%s(%d%d%d)%s")) or status
    headers = {}
    for name, value in block:gmatch("\r?\n([^:%s]+):%s*([^\r\n]+)") do
      headers[name:lower()] = vim.trim(value)
    end
  end
  if status == 0 then
    local status_line = raw:match("([^\r\n]+)")
    status = tonumber(status_line and status_line:match("%s(%d%d%d)%s")) or 0
    for name, value in raw:gmatch("\r?\n([^:%s]+):%s*([^\r\n]+)") do
      headers[name:lower()] = vim.trim(value)
    end
  end
  return status, headers
end

local function cleanup(paths)
  for _, path in ipairs(paths) do
    pcall(vim.uv.fs_unlink, path)
  end
end

function M.request(space, request)
  local opts = config.get().transport
  local header_path = temp_file()
  local body_path = temp_file()
  local cleanup_paths = { header_path, body_path }
  local args = {
    opts.executable,
    "--silent",
    "--show-error",
    "--request",
    request.method or "GET",
    "--max-time",
    tostring(math.max(1, math.ceil(opts.timeout_ms / 1000))),
    "--dump-header",
    header_path,
    "--output",
    body_path,
    "--header",
    "@-",
  }
  if space.tls and space.tls.ca_file then
    vim.list_extend(args, { "--cacert", space.tls.ca_file })
  end
  if request.body ~= nil then
    local upload_path = temp_file()
    table.insert(cleanup_paths, upload_path)
    local ok, err = write_file(upload_path, request.body)
    if not ok then
      cleanup(cleanup_paths)
      return nil, "cannot write request body: " .. tostring(err)
    end
    vim.list_extend(args, { "--upload-file", upload_path })
  end
  table.insert(args, request.url)

  local headers = vim.deepcopy(request.headers or {})
  headers["X-Sync-Mode"] = headers["X-Sync-Mode"] or "true"
  headers["X-Client-Id"] = headers["X-Client-Id"] or ("silverbullet.nvim-" .. state.session_id)
  headers["X-Source"] = headers["X-Source"] or "external"
  local token, token_err = config.resolve_token(space)
  if token_err then
    cleanup(cleanup_paths)
    return nil, token_err
  end
  if token then
    headers.Authorization = "Bearer " .. token
  end
  local header_lines = {}
  for name, value in pairs(headers) do
    table.insert(header_lines, ("%s: %s"):format(name, value))
  end
  table.sort(header_lines)

  local result = vim.system(args, {
    stdin = table.concat(header_lines, "\n") .. "\n",
    text = true,
    timeout = opts.timeout_ms + 1000,
  }):wait()
  local raw_headers = read_file(header_path)
  local body = read_file(body_path)
  cleanup(cleanup_paths)
  local status, response_headers = parse_headers(raw_headers)
  if result.code ~= 0 and status == 0 then
    return nil, log.redact(vim.trim(result.stderr or ("curl exited with " .. result.code)))
  end
  return {
    status = status,
    headers = response_headers,
    body = body,
    stderr = log.redact(result.stderr or ""),
  }
end

return M
