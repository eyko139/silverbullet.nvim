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
local extracted = links.extract("[[One]] and [[Two|second]]")
equal(2, #extracted, "extracts multiple wiki links")
equal("Two", extracted[2].page, "extracts the second wiki-link target")

equal([["Page \"One\"\\line\n"]], runtime.literal("Page \"One\"\\line\n"), "serializes Lua literals")
equal("Authorization: <redacted>", log.redact("Authorization: Bearer secret"), "redacts authorization")
equal("Bearer <redacted>", log.redact("Bearer abc.def"), "redacts bearer token")

local picker = require("silverbullet.picker")
equal("builtin", picker.resolve_provider("builtin"), "selects builtin picker")
local provider_ok, provider_err = pcall(picker.resolve_provider, "invalid")
assert(not provider_ok and provider_err:find("unsupported picker provider", 1, true), "rejects invalid picker")

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
local configured_space = require("silverbullet.config").space("test")
require("silverbullet.config").set_session_token("test", "test-token")
equal("test-token", require("silverbullet.config").resolve_token(configured_space), "uses session token override")
require("silverbullet.config").clear_session_token("test")
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

assert(fs.write("test", "Target.md", "# Target\n"))
assert(fs.write("test", "Source.md", "A [[Target]] link\nUnique searchable phrase\n"))
local completion_buf = vim.api.nvim_get_current_buf()
require("silverbullet.state").set(completion_buf, { space = "test" })
vim.api.nvim_buf_set_lines(completion_buf, 0, -1, false, { "[[Tar" })
vim.api.nvim_win_set_cursor(0, { 1, 5 })
local completion_items = require("silverbullet.completion").omnifunc(0, "Tar")
equal("Target]]", completion_items[1].word, "completion closes wiki links")
vim.api.nvim_buf_set_lines(completion_buf, 0, -1, false, { "[[Tar]]" })
vim.api.nvim_win_set_cursor(0, { 1, 5 })
completion_items = require("silverbullet.completion").omnifunc(0, "Tar")
equal("Target", completion_items[1].word, "completion does not duplicate closing brackets")
local search = require("silverbullet.search")
local matches = assert(search.full_text("test", "searchable phrase"))
equal(1, #matches, "finds text across remote pages")
equal("Source.md", matches[1].path, "returns the matching page")
equal(2, matches[1].lnum, "returns the matching line")
local backlinks = assert(search.backlinks("test", "Target.md"))
equal(1, #backlinks, "finds backlinks across remote pages")
equal("Source.md", backlinks[1].path, "returns backlink source page")
equal(1, backlinks[1].lnum, "returns backlink source line")

require("silverbullet.state").invalidate_search_index("test")
require("silverbullet.state").invalidate_content("test")
local indexed_read_count = 0
local indexed_fs_read = fs.read
fs.read = function(...)
  indexed_read_count = indexed_read_count + 1
  return indexed_fs_read(...)
end
assert(search.full_text("test", "Target"))
local initial_read_count = indexed_read_count
assert(initial_read_count > 0, "initial index downloads page content")
assert(search.full_text("test", "Target"))
equal(initial_read_count, indexed_read_count, "unchanged index avoids repeated page reads")
assert(fs.write("test", "Source.md", "A [[Target]] link\nUpdated searchable phrase with more text\n"))
require("silverbullet.state").invalidate_pages("test")
assert(search.full_text("test", "updated searchable"))
equal(initial_read_count + 1, indexed_read_count, "refreshes only the changed page")
fs.read = indexed_fs_read

local original_page_list = require("silverbullet.pages").list
local original_fs_read = fs.read
require("silverbullet.pages").list = function()
  return {
    { path = "Target.md", display = "Target", meta = {} },
    { path = "Missing.md", display = "Missing", meta = {} },
  }
end
fs.read = function(space_name, path)
  if path == "Missing.md" then
    return nil, ""
  end
  return original_fs_read(space_name, path)
end
require("silverbullet.state").invalidate_content("test")
local partial_documents, partial_err, failures = search.documents("test", { refresh = true })
assert(partial_documents and not partial_err, "continues indexing after one page fails")
equal(1, #partial_documents, "keeps successfully indexed pages")
equal(1, #failures, "reports skipped pages")
assert(search.failure_message(failures):find("unknown read failure", 1, true), "fills empty transport errors")
require("silverbullet.pages").list = original_page_list
fs.read = original_fs_read
require("silverbullet.state").invalidate_content("test")
require("silverbullet.state").invalidate_search_index("test")

require("silverbullet.buffer").open("test", "Buffer Page")
local buf = vim.api.nvim_get_current_buf()
local buffer_state = assert(require("silverbullet.state").get(buf))
equal("Buffer Page.md", buffer_state.path, "opens a virtual page buffer")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "buffer body" })
vim.bo[buf].endofline = false
vim.cmd.write()
equal("buffer body", assert(fs.read("test", "Buffer Page.md")).content, "writes through BufWriteCmd")
assert(fs.delete("test", "Buffer Page.md"))
assert(fs.delete("test", "Source.md"))
assert(fs.delete("test", "Target.md"))

print("silverbullet.nvim tests passed")
