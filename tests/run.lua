local function equal(expected, actual, label)
  if not vim.deep_equal(expected, actual) then
    error(("%s\nexpected: %s\nactual: %s"):format(label, vim.inspect(expected), vim.inspect(actual)))
  end
end

local uri = require("silverbullet.uri")
local links = require("silverbullet.links")
local runtime = require("silverbullet.client.runtime")
local log = require("silverbullet.log")

local path_cases = {
  "index.md",
  "Projects/Finnova.md",
  "Meeting Notes/Review.md",
  "ümlaut/Grüsse.md",
  "Page #1.md",
  "percent%page.md",
}
for _, path in ipairs(path_cases) do
  equal(path, assert(uri.normalize_path(path)), "normalizes " .. path)
  local buffer_uri = assert(uri.buffer_uri("test", path))
  equal(path, assert(uri.parse_buffer_uri(buffer_uri)).path, "round trips " .. path)
end
equal(nil, uri.normalize_path("../secret.md"), "rejects parent traversal")
equal(nil, uri.normalize_path("/absolute.md"), "rejects absolute paths")
equal("Page.md", uri.page_path("Page"), "adds markdown extension")
equal("Page.md", uri.page_path("Page.md"), "retains markdown extension")

equal({ page = "Page", alias = nil, heading = nil }, links.parse("Page"), "parses plain link")
equal({ page = "Page", alias = "Alias", heading = nil }, links.parse("Page|Alias"), "parses alias")
equal({ page = "Page", alias = nil, heading = "Heading" }, links.parse("Page#Heading"), "parses heading")
equal({ anchor = "$anchor", alias = nil }, links.parse("$anchor"), "parses anchor")
equal("Page", links.at_cursor("before [[Page]] after", 10).page, "finds cursor link")

equal([["Page \"One\"\\line\n"]], runtime.literal("Page \"One\"\\line\n"), "serializes Lua literals")
equal("Authorization: <redacted>", log.redact("Authorization: Bearer secret"), "redacts authorization")
equal("Bearer <redacted>", log.redact("Bearer abc.def"), "redacts bearer token")

local port = assert(vim.env.SILVERBULLET_TEST_PORT, "test server port is missing")
require("silverbullet").setup({
  default_space = "test",
  spaces = {
    test = {
      url = "http://127.0.0.1:" .. port,
      auth = { token_env = "SILVERBULLET_TEST_TOKEN" },
    },
  },
})

local fs = require("silverbullet.client.fs")
local files = assert(fs.list("test"))
equal(0, #files, "starts with an empty listing")

local first_meta = assert(fs.write("test", "Notes/Grüsse.md", "first\n", { create = true }))
local first = assert(fs.read("test", "Notes/Grüsse.md"))
equal("first\n", first.content, "reads written Unicode page")
assert(first.meta.etag or first_meta.etag, "server returned an ETag")

local old_etag = first.meta.etag
assert(fs.write("test", "Notes/Grüsse.md", "second\n", { etag = old_etag }))
local _, conflict_err, conflict_response = fs.write("test", "Notes/Grüsse.md", "stale\n", { etag = old_etag })
assert(conflict_err and conflict_response.status == 412, "stale ETag must conflict")

files = assert(fs.list("test"))
equal("Notes/Grüsse.md", files[1].name, "lists nested Unicode page")
assert(fs.delete("test", "Notes/Grüsse.md"))

require("silverbullet.buffer").open("test", "Buffer Page")
local buf = vim.api.nvim_get_current_buf()
local buffer_state = assert(require("silverbullet.state").get(buf))
equal("Buffer Page.md", buffer_state.path, "opens a virtual page buffer")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "buffer body" })
vim.bo[buf].endofline = false
vim.cmd.write()
equal("buffer body", assert(fs.read("test", "Buffer Page.md")).content, "writes through BufWriteCmd")
assert(fs.delete("test", "Buffer Page.md"))

print("silverbullet.nvim tests passed")
