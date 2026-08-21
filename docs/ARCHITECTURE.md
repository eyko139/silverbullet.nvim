# silverbullet.nvim architecture and internals

This document describes the implementation of `silverbullet.nvim`: how a
SilverBullet page becomes a Neovim buffer, which HTTP and Neovim APIs are
used, what each Lua module owns, and where the current boundaries and
limitations are.

It is written for maintainers, contributors, and users who want to understand
the plugin beyond its public setup interface.

## Contents

1. [Design goals](#design-goals)
2. [System overview](#system-overview)
3. [External APIs](#external-apis)
4. [Neovim integration](#neovim-integration)
5. [SilverBullet HTTP integration](#silverbullet-http-integration)
6. [Internal data models](#internal-data-models)
7. [Read lifecycle](#read-lifecycle)
8. [Write lifecycle](#write-lifecycle)
9. [Conflict detection](#conflict-detection)
10. [Path and URI handling](#path-and-uri-handling)
11. [Authentication and transport security](#authentication-and-transport-security)
12. [Module reference](#module-reference)
13. [Commands and events](#commands-and-events)
14. [Error handling](#error-handling)
15. [Testing](#testing)
16. [Extension points](#extension-points)
17. [Current limitations](#current-limitations)
18. [API references](#api-references)

## Design goals

The plugin treats a SilverBullet space as a remote Markdown filesystem rather
than trying to reproduce the SilverBullet browser client inside Neovim.

The core design principles are:

- **Normal editing semantics:** pages are regular Neovim buffers and are saved
  with `:write`.
- **No silent overwrite:** a detected remote edit must prevent an ordinary
  write.
- **Filesystem API first:** basic page editing must not depend on the optional
  SilverBullet Runtime API.
- **No mandatory plugin dependencies:** Telescope is used when available, with
  a `vim.ui.select()` fallback. Completion uses Neovim's omnifunc.
- **Transport isolation:** editor-facing code does not build `curl` commands
  or parse HTTP directly.
- **Late credential resolution:** tokens are obtained immediately before a
  request, not during startup.
- **No startup networking:** loading the plugin registers commands and
  autocommands only.

## System overview

```text
User command / autocommand
          |
          v
  buffer.lua / pages.lua / links.lua
          |
          v
      client/fs.lua  <------ client/runtime.lua
          |                     |
          +----------+----------+
                     v
             transport/curl.lua
                     |
                     v
             SilverBullet server
```

The main layers are:

| Layer | Responsibility |
| --- | --- |
| Plugin entry point | Register commands and Neovim autocommands |
| Editor workflows | Open, populate, save, reload, delete, and navigate buffers |
| Domain services | Page listing, wiki-link parsing, completion, conflicts |
| API clients | Represent SilverBullet filesystem and Runtime operations |
| Transport | Execute `curl`, pass credentials, collect HTTP responses |
| Shared state | Keep per-buffer baselines and short-lived page caches |

The dependency direction is intentionally one-way. The transport does not know
about Neovim buffers, and the buffer layer does not know how `curl` is invoked.

## External APIs

### Neovim APIs

The plugin targets Neovim 0.10 or newer and uses the following core APIs.

#### `vim.system()`

`vim.system(argv, opts)` executes `curl` and credential-provider commands
without constructing a shell command string.

The transport calls:

```lua
vim.system(args, {
  stdin = header_text,
  text = true,
  timeout = timeout_ms,
}):wait()
```

Important properties of this use:

- `args` is an argv table, so no `sh -c` or shell interpolation is involved.
- request headers are supplied through standard input;
- `:wait()` makes page reads and writes synchronous;
- the result supplies `code`, `stdout`, and `stderr`;
- Neovim's timeout is slightly longer than `curl --max-time`, allowing curl to
  report its own timeout first.

Synchronous writes are intentional. Neovim must not report `:write` as
successful before SilverBullet has accepted the content.

#### `BufReadCmd`

`BufReadCmd` replaces Neovim's normal filesystem read for names matching:

```text
silverbullet://*
```

When a URI is edited, `plugin/silverbullet.lua` passes the buffer and URI to
`silverbullet.buffer.load()`. No local file is read.

#### `BufWriteCmd`

SilverBullet page buffers use:

```lua
vim.bo[buf].buftype = "acwrite"
```

For an `acwrite` buffer, Neovim delegates writes to `BufWriteCmd`. The plugin
serializes the buffer and performs a remote `PUT`. If the write fails, the
autocommand raises an error and leaves the buffer modified.

#### Buffer APIs and options

The buffer layer uses:

- `nvim_buf_get_lines()` and `nvim_buf_set_lines()` for content;
- `nvim_buf_get_name()` and `nvim_buf_set_name()` for virtual names;
- `nvim_buf_get_mark()` and `nvim_win_set_cursor()` for cursor restoration;
- `nvim_buf_delete()` after remote deletion;
- `vim.bo[buf]` for buffer-local options.

Remote page buffers are configured as:

```lua
vim.bo[buf].buftype = "acwrite"
vim.bo[buf].filetype = "markdown"
vim.bo[buf].swapfile = false
vim.bo[buf].bufhidden = "hide"
```

`endofline` records whether the remote body ended with a newline. `readonly`
and `modifiable` reflect the remote permission metadata.

#### Commands and mappings

`nvim_create_user_command()` defines the public Ex commands.

`vim.keymap.set()` defines only `<Plug>` mappings. The plugin deliberately
does not assign user-facing keys.

#### User interfaces

`vim.ui.select()` is used for:

- page selection;
- deletion confirmation;
- conflict actions;
- the second force-overwrite confirmation.

Because `vim.ui.select()` is a standard UI hook, another plugin can replace
its presentation without changing `silverbullet.nvim`.

`vim.ui.open()` opens a page URL through the operating system's configured
handler.

#### Completion

The page buffer's `omnifunc` points to:

```text
v:lua.require'silverbullet.completion'.omnifunc
```

Neovim calls the function twice:

1. with `findstart == 1` to find the start of the completion text;
2. with `findstart == 0` to obtain matching page names.

#### Health checks

`lua/silverbullet/health.lua` exposes the standard `check()` entry point
discovered by:

```vim
:checkhealth silverbullet
```

It reports through `vim.health.start()`, `ok()`, `info()`, `warn()`, and
`error()`.

#### libuv

`vim.uv` is used for:

- mode-`0600` temporary files;
- file reads and writes;
- deleting temporary files;
- monotonic timestamps for cache expiry and external-change throttling.

### SilverBullet APIs

The core client uses the SilverBullet HTTP filesystem API.

| Method | Endpoint | Use |
| --- | --- | --- |
| `GET` | `/.ping` | Connectivity health check |
| `GET` | `/.config` | Authenticated server configuration check |
| `GET` | `/.fs` | List files and metadata |
| `GET` | `/.fs/{path}` | Read a page and response metadata |
| `PUT` | `/.fs/{path}` | Create or update a page |
| `DELETE` | `/.fs/{path}` | Delete a page |
| `POST` | `/.runtime/lua` | Evaluate an optional Runtime expression |

All requests made by the shared transport include:

```text
X-Sync-Mode: true
X-Client-Id: silverbullet.nvim-{session-id}
X-Source: external
```

Authenticated requests include:

```text
Authorization: Bearer {token}
```

The filesystem client consumes these response headers when present:

| Header | Internal field |
| --- | --- |
| `ETag` | `etag` |
| `X-Created` | `created` |
| `X-Last-Modified` | `last_modified` |
| `X-Content-Length` | `size` |
| `X-Permission` | `permission` |
| `Content-Type` | `content_type` |

The listing client also maps SilverBullet's JSON fields:

| JSON field | Internal field |
| --- | --- |
| `name` | `name` |
| `created` | `created` |
| `lastModified` | `last_modified` |
| `contentType` | `content_type` |
| `size` | `size` |
| `perm` | `permission` |

Unknown listing metadata is retained under the `raw` field.

### Conditional HTTP requests

Current SilverBullet versions expose content ETags and accept standard HTTP
preconditions:

```text
If-Match: "{etag}"
If-None-Match: *
```

The plugin uses `If-Match` when updating an existing page with a known ETag
and `If-None-Match: *` when creating a page. SilverBullet responds with
`412 Precondition Failed` when the condition is no longer true.

### Runtime API

The optional Runtime client currently supports only:

```text
POST /.runtime/lua
Content-Type: text/plain; charset=utf-8
```

The request body is a raw SilverBullet Lua expression. The Runtime API runs
inside a headless Chromium-backed SilverBullet client, so it is optional and
may be unavailable on installations without Chromium.

`runtime.literal()` serializes a Lua string literal so callers do not need to
interpolate unescaped page names into executable source.

The Runtime client exists as an infrastructure layer. User-facing tasks,
Runtime queries, anchors, and refactoring commands are not implemented yet.
Backlinks are implemented independently by scanning wiki links through the
filesystem API.

## Neovim integration

### Virtual buffer names

Each page is represented by a URI:

```text
silverbullet://{space}/{encoded-path}.md
```

Examples:

```text
silverbullet://personal/index.md
silverbullet://personal/Projects/Finnova.md
silverbullet://work/Meeting%20Notes/Review.md
```

The URI encodes the configured space name and full remote path. This gives a
page a stable Neovim buffer identity without creating a local mirror.

Opening the same URI lets Neovim reuse the existing buffer according to its
normal buffer rules.

### Registered autocommands

`plugin/silverbullet.lua` creates the `SilverBulletNvim` augroup.

| Event | Pattern | Action |
| --- | --- | --- |
| `BufReadCmd` | `silverbullet://*` | Fetch and populate the remote page |
| `BufWriteCmd` | `silverbullet://*` | Write the buffer through the API |
| `FocusGained` | `silverbullet://*` | Check for an external edit |
| `BufEnter` | `silverbullet://*` | Check for an external edit |
| `BufWipeout` | `silverbullet://*` | Remove per-buffer state |

`FocusGained` and `BufEnter` checks run only when the plugin has been
configured and `conflict.check_on_focus` is enabled.

### Startup behavior

The plugin entry point:

1. sets a standard `loaded_silverbullet_nvim` guard;
2. initializes the session ID;
3. registers commands;
4. registers autocommands.

It does not resolve credentials and does not contact SilverBullet during
startup.

## SilverBullet HTTP integration

### Normalized transport response

The curl transport returns:

```lua
{
  status = 200,
  headers = {
    ["content-type"] = "text/markdown",
    ["etag"] = '"sha256:..."',
  },
  body = "...",
  stderr = "",
}
```

Header names are normalized to lowercase. Redirect response blocks are parsed
so the final received HTTP status and header set are represented. Redirects
are not followed because the curl command does not include `--location`.

### Curl invocation

The generated command is conceptually:

```text
curl
  --silent
  --show-error
  --request METHOD
  --max-time SECONDS
  --dump-header HEADER_FILE
  --output BODY_FILE
  --header @-
  [--cacert CA_FILE]
  [--upload-file REQUEST_BODY_FILE]
  URL
```

Headers are written to curl's standard input. Request bodies are written to a
temporary file and sent with `--upload-file`.

Header, response-body, and request-body temporary files are removed after the
request.

### Status interpretation

`client/fs.lua` translates important statuses:

| Status | Meaning presented by the plugin |
| --- | --- |
| `2xx` | Successful request |
| `3xx` | Likely proxy authentication interception or wrong base URL |
| `401` | Missing or invalid SilverBullet authentication |
| `403` | Access denied or read-only server/page |
| `404` | Missing page |
| `412` | Remote page changed or create precondition failed |
| `5xx` | SilverBullet server failure |

An HTML `Content-Type` or an HTML document where JSON is expected is treated
as a likely reverse-proxy login page.

## Internal data models

### Configuration

After defaults are merged, the configuration is conceptually:

```lua
{
  default_space = "personal",
  spaces = {
    personal = {
      url = "https://bullet.example.com",
      auth = {
        token_env = "SILVERBULLET_TOKEN",
      },
      runtime = {
        enabled = false,
      },
      tls = {
        ca_file = "/optional/private-ca.pem",
      },
    },
  },
  transport = {
    executable = "curl",
    timeout_ms = 10000,
  },
  cache = {
    page_list_ttl_ms = 5000,
    page_content_ttl_ms = 30000,
  },
  conflict = {
    check_on_focus = true,
    check_before_write = true,
  },
  picker = {
    provider = "auto",
    telescope = {},
  },
}
```

### Buffer state

`state.buffers[bufnr]` contains:

```lua
{
  space = "personal",
  path = "Projects/Finnova.md",
  base_content = "content originally loaded or last saved",
  base_hash = "sha256...",
  etag = '"sha256:..."' or nil,
  last_modified = 1234567890 or nil,
  permission = "rw" or "ro",
  writing = false,
  exists = true,
  last_check = monotonic_time_ms,
}
```

The important distinction is between:

- the current Neovim buffer content;
- `base_content`, the last accepted remote baseline;
- the current remote content, fetched only when needed.

`base_hash` is calculated with `vim.fn.sha256()` and supports servers that do
not provide ETags.

### Page cache

`state.page_cache[space]` contains:

```lua
{
  at = monotonic_time_ms,
  pages = {
    {
      path = "Projects/Finnova.md",
      display = "Projects/Finnova",
      meta = {},
    },
  },
}
```

The cache expires after `cache.page_list_ttl_ms` and is invalidated after a
successful write or delete.

### Content cache

`state.content_cache[space][path]` contains:

```lua
{
  at = monotonic_time_ms,
  content = "remote Markdown body",
  meta = {},
}
```

This cache is shared by full-text search, backlink discovery, and Telescope
previews during individual reads. Entries expire after
`cache.page_content_ttl_ms`. Once a page is part of the search index, the
indexed document is preferred instead.

### Search index

`state.search_indexes[space]` contains:

```lua
{
  documents = {
    ["Projects/Finnova.md"] = {
      path = "Projects/Finnova.md",
      display = "Projects/Finnova",
      content = "...",
      meta = {
        last_modified = 1787300000000,
        size = 1234,
      },
      list_meta = {
        last_modified = 1787300000000,
        size = 1234,
      },
      indexed_at = 123456,
      lines = { "# Finnova", "..." },
      outgoing = {
        {
          target = "roadmap.md",
          lnum = 12,
          col = 8,
          text = "See [[Roadmap]]",
        },
      },
    },
  },
  lines = {
    {
      path = "Projects/Finnova.md",
      lnum = 12,
      col = 1,
      text = "See [[Roadmap]]",
    },
  },
  incoming = {
    ["roadmap.md"] = {
      {
        path = "Projects/Finnova.md",
        lnum = 12,
        col = 8,
        text = "See [[Roadmap]]",
      },
    },
  },
}
```

`documents` is the source of truth. `lines` and `incoming` are derived lookup
structures rebuilt locally after a document changes.

`list_meta` is kept separately from metadata returned by an individual page
read. Only listing metadata is compared during later refreshes, avoiding
differences in header representation from causing unnecessary re-downloads.
When a listing provides neither modification time nor size, `indexed_at` and
`cache.page_content_ttl_ms` provide a periodic refresh fallback.

`state.search_index_dirty[space][path]` marks pages changed by a successful
plugin write or delete. The next index refresh downloads those paths even
before metadata comparison.

The index lasts for the Neovim process. It is not written to disk because page
content may be sensitive and persistent local storage should be an explicit
future feature.

### Session ID

`state.init()` creates one process-local identifier from the current time,
Neovim PID, and a random value. It is sent as part of `X-Client-Id` to help
SilverBullet distinguish this editor session.

It is an identifier, not an authentication secret.

## Read lifecycle

Opening a page follows this sequence:

```text
:SilverBulletOpen Projects/Finnova
        |
        v
normalize path and add .md
        |
        v
build silverbullet:// URI
        |
        v
:edit URI
        |
        v
BufReadCmd
        |
        v
GET /.fs/Projects/Finnova.md
        |
        v
populate buffer and record baseline
```

In detail:

1. `buffer.open()` resolves the requested or default space.
2. `uri.page_path()` validates the page name and adds `.md` when absent.
3. `uri.buffer_uri()` percent-encodes path segments and creates the virtual
   buffer name.
4. `vim.cmd.edit()` opens that URI.
5. `BufReadCmd` calls `buffer.load()`.
6. The URI is parsed back into a space and path.
7. The buffer is configured as an `acwrite` Markdown buffer.
8. `fs.read()` performs `GET /.fs/{path}`.
9. A `404` creates an empty, not-yet-existing page buffer.
10. A successful response is split into Neovim lines.
11. `endofline` is set to preserve the remote final newline.
12. response metadata and a SHA-256 baseline are stored.
13. `modified` is cleared only after population succeeds.
14. the previous cursor mark is restored when possible.

No page is created remotely until the empty buffer is written.

## Write lifecycle

Writing follows this sequence:

```text
:write
  |
  v
BufWriteCmd
  |
  v
serialize buffer
  |
  +--> new page: verify absent, use If-None-Match: *
  |
  +--> known ETag: use If-Match
  |
  +--> no ETag: fetch and compare baseline hash
  |
  v
PUT /.fs/{path}
  |
  v
update baseline and clear modified
```

In detail:

1. `buffer.write()` verifies that the buffer has managed state.
2. It rejects overlapping writes through the `writing` flag.
3. It rejects known read-only pages.
4. It joins buffer lines with `\n`.
5. It appends a final newline only when `vim.bo.endofline` is set.
6. It chooses the strongest available precondition.
7. It performs a synchronous `PUT`.
8. A failed request leaves `modified` unchanged.
9. A successful request updates the baseline hash, ETag, timestamps, and
   existence flag.
10. If the successful `PUT` did not return an ETag, the page is read once to
    acquire updated metadata when possible.
11. The page-list cache is invalidated.
12. `modified` is cleared.
13. a `User SilverBulletWritePost` event is emitted.

The event includes:

```lua
{
  buf = bufnr,
  space = "personal",
  path = "Projects/Finnova.md",
}
```

Consumers can listen with:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "SilverBulletWritePost",
  callback = function(args)
    local data = args.data
    -- React to a completed remote write.
  end,
})
```

## Conflict detection

### ETag-capable servers

When a page read returns an ETag, the next ordinary write includes:

```text
If-Match: {previous-etag}
```

The server accepts the write only if the page still has the same content.
This closes the race atomically on the server.

New pages use:

```text
If-None-Match: *
```

Before that conditional `PUT`, the implementation also performs a read. This
provides an immediate conflict interface if another client created the page.
The HTTP precondition remains necessary because creation could occur between
the check and the write.

### SilverBullet 2.9 fallback

If no ETag was observed:

1. the original body hash is stored as `base_hash`;
2. immediately before writing, the plugin reads the page again;
3. the remote body hash is compared with `base_hash`;
4. a mismatch refuses the write;
5. a match allows an unconditional `PUT`.

This detects normal concurrent edits but has a small race between the final
`GET` and `PUT`. Complete atomic protection requires server-side conditional
writes.

### External-change checks

On `FocusGained` and `BufEnter`, checks are throttled to at most one per second
per buffer.

If the remote hash changed:

- a clean buffer is replaced with the remote content and its cursor is
  preserved;
- a modified buffer is left untouched and a warning is shown.

### Conflict UI

`conflict.handle()` schedules a `vim.ui.select()` prompt with:

- **Show diff:** opens a read-only scratch buffer and enables Neovim diff mode
  in both windows;
- **Reload remote:** discards the local content and reloads;
- **Force overwrite:** requires a second confirmation, then writes without a
  precondition;
- **Cancel:** performs no action.

The force operation is intentionally explicit and is never an automatic retry.

## Path and URI handling

All remote paths pass through `uri.lua`.

### Validation

`normalize_path()`:

- requires a string;
- trims surrounding whitespace;
- converts backslashes to `/`;
- collapses repeated separators;
- rejects empty paths;
- rejects absolute paths;
- rejects `..` components;
- removes `.` components.

This prevents an API path from escaping the configured SilverBullet space.

### Encoding

Each path component is encoded independently. `/` remains a hierarchy
separator, while unsafe bytes become uppercase percent escapes.

For example:

```text
Meeting Notes/Page #1.md
```

becomes:

```text
Meeting%20Notes/Page%20%231.md
```

UTF-8 is encoded byte by byte, which is the standard URI percent-encoding
representation for Unicode paths.

### Page paths versus file paths

`page_path()` adds `.md` only when it is absent. `encode_path()` itself does
not add an extension, so the lower-level filesystem client remains usable for
non-page paths in future attachment support.

## Authentication and transport security

### Credential providers

`config.resolve_token()` supports:

1. a session-only token set through `SilverBulletSetToken`;
2. `auth.token_env`: read a named environment variable;
3. `auth.token`: call a Lua function;
4. `auth.command`: execute an argv table and trim stdout.

The first available provider in that order is used. Session tokens are held in
a private table keyed by the configured space object and are cleared when
`setup()` runs again or Neovim exits.

Literal token values are rejected during setup because `auth.token` must be a
function.

### Process visibility

The token is not included in the curl argv. It is placed in a header block sent
through standard input using curl's `--header @-` support.

This prevents the bearer token from appearing in ordinary process listings.

Credential commands are also executed with argv tables rather than shell
strings. A secret manager command may still have its own process-level
security properties, but the returned token is not appended to curl's argv.

### Temporary files

Request bodies and response data use temporary files because this allows curl
to upload arbitrary Markdown content without embedding it in arguments.

Files are created with decimal mode `384`, equivalent to Unix `0600`.

Cleanup runs after both successful and failed requests where the transport has
control. Authentication headers are never written to these files.

### TLS and redirects

TLS certificate verification remains enabled. A private CA can be supplied
with:

```lua
tls = {
  ca_file = "/path/to/private-ca.pem",
}
```

The transport does not use curl's `--insecure` option.

Redirects are not followed. This is deliberate: a redirect commonly means
Authelia or another browser-oriented authentication layer intercepted the API
request.

### Redaction

`log.redact()` removes authorization headers and bearer-token-looking values
before they are passed to `vim.notify()` or returned from transport errors.

Callers adding new error paths should route potentially sensitive text through
this module.

## Module reference

### `plugin/silverbullet.lua`

The runtime entry point loaded by Neovim's plugin mechanism.

Responsibilities:

- enforce one-time loading;
- initialize process state;
- register commands;
- register URI read/write, focus, enter, and wipeout autocommands.

It should remain small and must not perform network requests.

### `lua/silverbullet/init.lua`

The public Lua API.

Exports:

```lua
require("silverbullet").setup(opts)
require("silverbullet").open(page, space)
require("silverbullet").find(space)
```

`setup()` initializes state, validates configuration, and ensures commands are
registered. `open()` and `find()` are small delegating convenience functions.

### `lua/silverbullet/config.lua`

Owns configuration defaults, validation, space resolution, and credentials.

Key functions:

- `setup(opts)`: deep-merge defaults and validate the result;
- `get()`: return configured options or raise a setup error;
- `space(name)`: resolve a named or default space;
- `resolve_token(space)`: invoke the configured credential provider;
- `is_configured()`: allow startup-safe checks.

The module keeps the active configuration in a private module-local variable.

### `lua/silverbullet/state.lua`

Holds process-local mutable state:

- per-buffer remote baselines;
- per-space page-list caches;
- the session/client identifier.

It deliberately contains no transport or UI logic.

### `lua/silverbullet/uri.lua`

Centralizes:

- path normalization;
- `.md` page extension handling;
- component-wise percent encoding;
- `silverbullet://` URI creation and parsing;
- browser page URL creation.

No other module should implement its own remote path escaping.

### `lua/silverbullet/log.lua`

Provides redacted notifications:

- `redact(value)`;
- `notify(message, level)`;
- `warn(message)`;
- `error(message)`.

The notification title is always `silverbullet.nvim`.

### `lua/silverbullet/async.lua`

Currently contains a minimal `vim.schedule()` wrapper.

It is not used by the current synchronous core. It reserves a small
abstraction point for future asynchronous list/picker work without changing
callers to depend directly on scheduling details.

### `lua/silverbullet/transport/curl.lua`

The only module that invokes curl.

Responsibilities:

- create secure temporary files;
- assemble curl argv;
- resolve and attach authentication;
- attach SilverBullet sync/client headers;
- support a custom CA;
- pass request headers on stdin;
- write PUT bodies to temporary files;
- parse status and response headers;
- normalize response objects;
- redact transport errors;
- remove temporary files.

It knows nothing about pages, buffers, or wiki links.

### `lua/silverbullet/client/fs.lua`

The typed semantic wrapper around SilverBullet's filesystem API.

Exports:

- `ping(space)`;
- `server_config(space)`;
- `list(space)`;
- `read(space, path)`;
- `write(space, path, content, precondition)`;
- `delete(space, path)`;
- `describe_error(response, operation)`.

It performs path encoding, JSON decoding, metadata mapping, HTTP status
translation, and login-page detection.

### `lua/silverbullet/client/runtime.lua`

The optional Runtime API wrapper.

Exports:

- `literal(value)`: safely quote a Lua string;
- `eval(space, expression)`: post a raw expression to `/.runtime/lua`.

It checks `space.runtime.enabled` before making a request. It returns decoded
JSON when possible and the raw response body otherwise.

### `lua/silverbullet/buffer.lua`

The central editor workflow module.

Responsibilities:

- configure remote buffers;
- translate HTTP bodies to lines and back;
- preserve final-newline state;
- open virtual URIs;
- load and reload pages;
- perform guarded writes;
- update baselines after successful writes;
- delete pages;
- detect external edits;
- emit `SilverBulletWritePost`.

Most correctness-sensitive behavior is concentrated here.

### `lua/silverbullet/conflict.lua`

Owns the conflict user interface.

It can:

- fetch the latest remote page after a `412`;
- display a two-window diff;
- reload the page;
- run a separately confirmed force write.

The remote diff buffer is `nofile`, read-only, swapless, and wiped when hidden.

### `lua/silverbullet/pages.lua`

Converts the raw filesystem listing into page entries.

It:

- retains only `.md` files;
- rejects a non-Markdown content type when one is supplied;
- removes `.md` for display;
- sorts case-insensitively;
- caches pages by space;
- supplies simple substring completion.

### `lua/silverbullet/search.lua`

Provides the remote-content index shared by search, backlinks, and previews.

It:

- reads pages through `client/fs.lua`;
- keeps a session-local document index per space;
- compares `last_modified` and `size` from `pages.list()` with indexed
  metadata;
- downloads only new, changed, or explicitly invalidated pages after the
  initial build;
- removes documents no longer present in the listing;
- skips individual pages that fail to load and returns structured failure
  details alongside the usable document index;
- builds searchable line entries;
- exposes case-insensitive literal full-text matching entirely against local
  indexed lines;
- records page, line, column, and complete page content for every result;
- extracts outgoing wiki links and builds an inverted target-to-source
  backlink map;
- excludes self-links from backlink results.

The index is built from ordinary filesystem API reads and does not require the
Runtime API. Initial construction still requires one read per Markdown page;
subsequent refreshes normally require only the listing request.

### `lua/silverbullet/picker/init.lua`

Selects a picker provider.

Accepted values are:

- `auto`: use Telescope when its picker module can be loaded, otherwise use
  the builtin provider;
- `telescope`: require Telescope and report a clear error if it is absent;
- `builtin`: always use `vim.ui.select()`.

Provider selection is isolated from page retrieval and buffer opening. The
module dispatches page finding, full-text search, and backlinks to the selected
provider.

### `lua/silverbullet/picker/common.lua`

Contains behavior shared by picker providers:

- formatting a `page:line: text` result;
- opening the selected source page;
- placing the cursor at the matching line and column.

### `lua/silverbullet/picker/builtin.lua`

Fetches pages through `pages.lua`, displays them with `vim.ui.select()`, and
opens the selected page. For full-text search it prompts with `vim.ui.input()`,
performs a literal search through `search.lua`, and presents matches with
`vim.ui.select()`. Backlinks use the same result selector.

It contains no HTTP or cache logic.

### `lua/silverbullet/picker/telescope.lua`

Provides page, full-text, and backlink pickers through Telescope.

It:

- obtains the same cached page entries as the builtin picker;
- creates entries whose display text omits `.md`;
- includes both display text and the full path in Telescope's `ordinal` field;
- uses Telescope's generic sorter;
- replaces the default selection action;
- closes Telescope before opening the selected SilverBullet buffer;
- loads remote Markdown into a buffer previewer;
- positions previews at matching search or backlink lines;
- indexes every non-empty page line for interactive full-text fuzzy search;
- accepts picker options from `picker.telescope`.

Telescope remains optional because this module is loaded only after provider
selection confirms it is available.

### `lua/silverbullet/links.lua`

Parses and follows SilverBullet wiki links.

Supported forms:

```text
[[Page]]
[[Folder/Page]]
[[Page|Alias]]
[[Page#Heading]]
[[#Heading]]
```

`at_cursor()` scans complete `[[...]]` ranges on the current line and selects
the one containing the cursor byte position.

`extract()` returns every complete wiki link in a line together with its byte
columns. The backlink index uses this parser rather than a second link syntax
implementation.

Heading navigation compares Markdown ATX heading text case-insensitively.

`[[$anchor]]` is parsed but currently reports that Runtime API support is
required.

### `lua/silverbullet/completion.lua`

Implements the built-in omnifunc.

Completion activates only when the cursor is inside an unclosed `[[...`
sequence on the current line. Matches are page display names containing the
typed prefix, case-insensitively.

### `lua/silverbullet/commands.lua`

Registers all Ex commands and `<Plug>` mappings once.

The `configured()` wrapper:

- prevents network workflows before `setup()`;
- catches command callback errors;
- displays errors through the redacting log module.

Commands that require a page call `current_state()` to verify that the current
buffer is managed by the plugin.

### `lua/silverbullet/health.lua`

Implements diagnostics for:

- Neovim version;
- curl availability and version;
- configuration presence;
- custom CA readability;
- credential-provider availability;
- `/.ping`;
- authenticated `/.config`;
- authenticated `/.fs`;
- read-only files in the listing;
- observable ETag support;
- optional Runtime API availability;
- redirects and HTML login interception.

Health checks intentionally avoid printing credentials or request headers.

## Commands and events

### Commands

| Command | Implementation |
| --- | --- |
| `SilverBulletHealth` | Executes `checkhealth silverbullet` |
| `SilverBulletSetToken [space]` | Prompts with `inputsecret()` and sets an in-memory token override |
| `SilverBulletFind` | Calls the configured page picker |
| `SilverBulletSearch [query]` | Searches all indexed page lines |
| `SilverBulletBacklinks` | Finds wiki links targeting the current page |
| `SilverBulletOpen` | Opens a normalized page in the default space |
| `SilverBulletNew` | Uses the same open path; a `404` becomes an empty buffer |
| `SilverBulletReload[!]` | Reloads, optionally discarding local edits |
| `SilverBulletDelete` | Confirms and sends `DELETE` |
| `SilverBulletFollowLink` | Parses the link under the cursor and opens it |
| `SilverBulletOpenWeb` | Converts the current path to a browser URL |
| `SilverBulletHome` | Opens `index.md` |

`SilverBulletOpen` and `SilverBulletNew` currently differ semantically for the
user but share the same implementation. Whether the page exists is discovered
during `BufReadCmd`.

### Plug mappings

```text
<Plug>(SilverBulletFind)
<Plug>(SilverBulletSetToken)
<Plug>(SilverBulletSearch)
<Plug>(SilverBulletBacklinks)
<Plug>(SilverBulletFollowLink)
<Plug>(SilverBulletOpenWeb)
```

### User event

```text
User SilverBulletWritePost
```

The event runs only after a successful remote write and baseline update.

## Error handling

The code generally uses the Lua convention:

```lua
result, error_message, optional_response
```

Transport failures have no HTTP response. HTTP failures return both a
human-readable message and the normalized response so callers can branch on
status, particularly `404` and `412`.

Important safety behavior:

- failed reads do not replace existing local buffer content;
- failed writes do not clear `modified`;
- a concurrent write is never retried unconditionally;
- modified buffers are not auto-reloaded;
- invalid paths stop before transport;
- configuration errors are raised during setup;
- credential errors occur immediately before the attempted request;
- notifications pass through token redaction.

## Testing

### `tests/minimal_init.lua`

Prepends the repository to `runtimepath` and supplies the mock token used by
transport tests.

### `tests/mock_server.py`

Starts an in-memory threaded HTTP server on a random localhost port.

It implements:

- bearer authentication;
- `/.ping`;
- `/.config`;
- `/.fs` listing;
- page `GET`;
- conditional page `PUT`;
- page `DELETE`;
- ETag generation.

The mock uses SHA-256 ETags and returns `412` for stale `If-Match` or failed
`If-None-Match` conditions.

### `tests/run.lua`

The current test coverage includes:

- path normalization;
- traversal and absolute-path rejection;
- `.md` extension behavior;
- Unicode and reserved-character URI round trips;
- wiki-link parsing and cursor lookup;
- extraction of multiple wiki links from one line;
- Runtime Lua-literal escaping;
- credential redaction;
- authenticated listing;
- nested Unicode page writes and reads;
- ETag conflict rejection;
- full-text matching across remote pages;
- backlink discovery and source locations;
- deletion;
- virtual-buffer opening;
- `BufWriteCmd` persistence;
- final-newline preservation for the exercised buffer case.

### `scripts/test`

The test script:

1. creates a temporary port file;
2. starts the mock server;
3. waits for its selected port;
4. exports the port to Neovim;
5. runs Neovim headlessly with the minimal configuration;
6. terminates the mock server and removes the temporary file.

## Extension points

### Alternative picker

A picker should consume `pages.list()` and call `buffer.open()`. It should not
access the transport directly. The builtin and Telescope providers both follow
this boundary.

The provider selection belongs in `picker/init.lua`, while provider-specific
UI belongs in a separate module.

### Asynchronous page listing

Writes should remain synchronous, but page listing and completion can be moved
to callback-based asynchronous transport later. `async.lua` is the current
placeholder for scheduling abstraction.

### Runtime-backed features

Tasks, anchors, arbitrary SilverBullet queries, and rename should be built on
`client/runtime.lua`. Backlinks currently use direct wiki-link scanning; a
future Runtime-backed strategy could include references derived from indexed
objects that are not represented by literal wiki links.

Any value embedded in a SilverBullet Lua expression must pass through
`runtime.literal()` or a future structured serializer. Page names must never
be concatenated into executable Lua source unescaped.

### Local filesystem backend

The buffer and navigation layers depend mainly on the semantic operations in
`client/fs.lua`. A future backend interface could provide `list`, `read`,
`write`, and `delete` without changing URI buffers or link parsing.

### Completion adapters

Framework-specific completion integrations should call `pages.complete()`.
The page service should remain independent of nvim-cmp, Blink, or another
completion protocol.

## Current limitations

This section documents the current implementation rather than planned
features.

- The Runtime API wrapper is present, but no Runtime-backed user commands are
  implemented.
- `$anchor` links are recognized but cannot be resolved.
- Heading matching is textual and case-insensitive; it does not implement
  SilverBullet's full heading/anchor normalization rules.
- Completion is synchronous and uses simple case-insensitive substring
  matching.
- The builtin picker sorts alphabetically and relies on the active
  `vim.ui.select()` implementation for filtering. Telescope provides fuzzy
  matching when installed.
- Neither picker currently applies custom exact-basename, path-component, or
  recency weighting beyond its provider's normal sorter.
- Full-text indexing reads every Markdown page synchronously when its content
  is first indexed, which can be slow for large or high-latency spaces.
- The incremental index is process-local and is rebuilt after restarting
  Neovim.
- Unreadable or stale listing entries are skipped with a warning. Results from
  successfully indexed pages remain available.
- Telescope full-text search indexes non-empty lines rather than tokenized
  documents.
- Backlinks recognize literal wiki links whose normalized page path matches
  the target. They do not include dynamically generated or Runtime-indexed
  references.
- External edits can remain stale until the page-list cache expires after
  `cache.page_list_ttl_ms`.
- `async.lua` is not used by the current workflows.
- Conflict diffing is two-way: local content versus the latest remote content.
  There is no three-way merge UI using the stored baseline.
- External-change detection compares full content hashes and does not use a
  metadata-only request.
- The non-ETag conflict fallback has an unavoidable `GET`/`PUT` race.
- Delete requests are currently unconditional and do not attach `If-Match`.
- A forced overwrite deliberately sends no precondition.
- There is no offline cache or synchronization queue.
- Attachments and image pasting are not implemented.
- Read, write, page listing, content indexing, completion, previews, and
  health requests are synchronous.
- The transport is designed for Linux and macOS behavior; Windows temporary
  file and curl behavior has not been validated.

## API references

The implementation is based on:

- [SilverBullet HTTP API](https://github.com/silverbulletmd/silverbullet/blob/main/docs/HTTP%20API.md)
- [SilverBullet Runtime API](https://github.com/silverbulletmd/silverbullet/blob/main/docs/Runtime%20API.md)
- [Neovim Lua API](https://neovim.io/doc/user/lua.html)
- [Neovim API](https://neovim.io/doc/user/api.html)
- [Neovim autocommands](https://neovim.io/doc/user/autocmd.html)
- [Neovim `:checkhealth`](https://neovim.io/doc/user/health.html)
