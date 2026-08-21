# silverbullet.nvim

Edit a remote [SilverBullet](https://silverbullet.md) space as a native Neovim
Markdown workspace.

Pages open in normal buffers, `:write` saves them to SilverBullet, wiki links
remain navigable, and concurrent browser edits are detected before they can be
overwritten.

## Features

- Open, create, edit, reload, and delete remote Markdown pages
- Use normal Neovim buffers and `:write`
- Fuzzy-find pages with Telescope when available
- Fall back to the dependency-free `vim.ui.select()` picker
- Preview remote Markdown pages inside Telescope
- Search the full text of every page in a space
- Find wiki-link backlinks to the current page
- Follow `[[Page]]`, `[[Page|Alias]]`, and `[[Page#Heading]]` links
- Detect remote changes with ETags or a SilverBullet 2.9-compatible fallback
- Open the current page in a browser
- Complete page names inside wiki links with the built-in omnifunc
- Connect to multiple named SilverBullet spaces
- Resolve credentials only when making a request
- Diagnose configuration, authentication, proxy, and connectivity problems
  with `:checkhealth silverbullet`
- Use only core Neovim APIs and `curl`; no plugin dependencies are mandatory

## Requirements

- Neovim 0.10 or newer
- SilverBullet 2.9 or newer
- `curl` available on `PATH`

### Optional dependencies

- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) for fuzzy
  page and content search with Markdown previews. It is selected automatically
  when installed.

## Installation

### lazy.nvim

```lua
{
  "lkuehne123/silverbullet.nvim",
  opts = {
    default_space = "personal",
    spaces = {
      personal = {
        url = "https://bullet.example.com",
        auth = {
          token_env = "SILVERBULLET_TOKEN",
        },
      },
    },
  },
}
```

For local development:

```lua
{
  dir = "/path/to/silverbullet.nvim",
  opts = {
    default_space = "personal",
    spaces = {
      personal = {
        url = "https://bullet.example.com",
        auth = {
          token_env = "SILVERBULLET_TOKEN",
        },
      },
    },
  },
}
```

### packer.nvim

```lua
use({
  "lkuehne123/silverbullet.nvim",
  config = function()
    require("silverbullet").setup({
      default_space = "personal",
      spaces = {
        personal = {
          url = "https://bullet.example.com",
          auth = {
            token_env = "SILVERBULLET_TOKEN",
          },
        },
      },
    })
  end,
})
```

### Native packages

```sh
git clone https://github.com/lkuehne123/silverbullet.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/silverbullet.nvim
```

Then configure the plugin in `init.lua`:

```lua
require("silverbullet").setup({
  default_space = "personal",
  spaces = {
    personal = {
      url = "https://bullet.example.com",
      auth = {
        token_env = "SILVERBULLET_TOKEN",
      },
    },
  },
})
```

## Authentication

Use an environment variable whenever possible:

```lua
auth = { token_env = "SILVERBULLET_TOKEN" }
```

```sh
export SILVERBULLET_TOKEN="your-token"
```

Alternatively, `auth.token` may be a Lua callback and `auth.command` may be an
argv table that prints the token. Literal tokens in configuration are
rejected.

To enter a token securely for the current Neovim session, run
`:SilverBulletSetToken [space]` or map `<Plug>(SilverBulletSetToken)`. The
prompt uses `inputsecret()` and the token is kept only in memory.

## Configuration

```lua
require("silverbullet").setup({
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
      -- Optional private certificate authority:
      -- tls = {
      --   ca_file = "/path/to/private-ca.pem",
      -- },
    },

    work = {
      url = "https://work-bullet.example.com",
      auth = {
        command = { "op", "read", "op://Work/SilverBullet/token" },
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
    -- "auto" uses Telescope when available, then falls back to vim.ui.select().
    -- Explicit alternatives: "telescope" or "builtin".
    provider = "auto",
    telescope = {
      -- Any Telescope picker options, for example:
      -- layout_strategy = "vertical",
    },
  },
})
```

Credentials are resolved immediately before each request. Authentication
headers are passed to `curl` through standard input rather than command-line
arguments.

## Usage

Start with:

```vim
:checkhealth silverbullet
:SilverBulletFind
```

| Command | Description |
| --- | --- |
| `:SilverBulletSetToken [space]` | Prompt for a session-only API token |
| `:SilverBulletFind` | Select and open a page |
| `:SilverBulletSearch [query]` | Search across the contents of all pages |
| `:SilverBulletBacklinks` | Find pages linking to the current page |
| `:SilverBulletOpen {page}` | Open an existing page |
| `:SilverBulletNew {page}` | Open a new empty page |
| `:SilverBulletReload` | Reload the current page |
| `:SilverBulletReload!` | Discard local changes and reload |
| `:SilverBulletDelete` | Delete the current page after confirmation |
| `:SilverBulletFollowLink` | Follow the wiki link under the cursor |
| `:SilverBulletOpenWeb` | Open the current page in a browser |
| `:SilverBulletHome` | Open `index.md` |
| `:SilverBulletHealth` | Run the SilverBullet health check |

New pages are created when their buffer is first written.

### Keymaps

The plugin does not define opinionated default keymaps. It provides `<Plug>`
mappings that can be assigned in your configuration:

```lua
vim.keymap.set("n", "<leader>sf", "<Plug>(SilverBulletFind)")
vim.keymap.set("n", "<leader>sk", "<Plug>(SilverBulletSetToken)")
vim.keymap.set("n", "<leader>ss", "<Plug>(SilverBulletSearch)")
vim.keymap.set("n", "<leader>sb", "<Plug>(SilverBulletBacklinks)")
vim.keymap.set("n", "<CR>", "<Plug>(SilverBulletFollowLink)")
vim.keymap.set("n", "<leader>so", "<Plug>(SilverBulletOpenWeb)")
```

#### Example: use `gd` to follow wiki links

This buffer-local mapping uses `gd` as "go to definition" for SilverBullet
wiki links without replacing the normal LSP mapping in other buffers:

```lua
vim.api.nvim_create_autocmd("BufEnter", {
  pattern = "silverbullet://*",
  callback = function(event)
    vim.keymap.set(
      "n",
      "gd",
      "<Plug>(SilverBulletFollowLink)",
      {
        buffer = event.buf,
        desc = "[G]oto SilverBullet [D]efinition",
      }
    )
  end,
})
```

### Full-text search

```vim
:SilverBulletSearch
:SilverBulletSearch deployment notes
```

The first search in a Neovim session builds a shared local index of page
content, searchable lines, and outgoing wiki links. Later searches compare the
cached document metadata with `GET /.fs` and download only new or changed
pages. Writes and deletes made through the plugin invalidate the affected
document immediately.

With Telescope, each indexed non-empty line becomes a fuzzy-searchable entry
and the complete page is shown in a Markdown preview at the matching line. The
optional command argument becomes Telescope's initial query.

The builtin provider prompts for a query and performs a
case-insensitive literal search before showing the results with
`vim.ui.select()`.

If an individual listing entry cannot be read, indexing skips that page,
reports the failure, and continues with the remaining pages. Search fails
entirely only when no page can be indexed.

### Backlinks

Run `:SilverBulletBacklinks` from a SilverBullet page to find other pages
containing `[[wiki links]]` to it. Selecting a result opens the source page at
the matching line.

Backlinks are computed from the filesystem API and do not require
SilverBullet's optional Runtime API. They use the same incremental document
index as full-text search, so backlink lookup is immediate after the index has
been built. Telescope displays each source page in a Markdown preview.

### Telescope previews

The page, full-text search, and backlink pickers preview remote Markdown when
Telescope is active. Disable previews or pass any other picker option through
the Telescope configuration:

```lua
picker = {
  provider = "auto",
  telescope = {
    previewer = false,
    layout_strategy = "vertical",
  },
}
```

### Completion

Page completion is available inside `[[...]]` through Neovim's omnifunc:

```text
<C-x><C-o>
```

## Reverse proxies and Authelia

Authelia or another authentication middleware may redirect terminal API
requests to an HTML login page before they reach SilverBullet.

Configure the reverse proxy with a higher-priority route for `/.fs` and,
when enabled, `/.runtime`. Keep HTTPS and SilverBullet's own token
authentication enabled on that route.

The health check reports redirects and unexpected HTML responses explicitly.

## Health checks

Run:

```vim
:checkhealth silverbullet
```

The check covers Neovim and `curl` versions, configuration, credential
providers, connectivity, authentication, filesystem access, custom CA files,
ETag support, and the optional Runtime API.

## Known limitations

- The full-text and backlink index is created lazily on the first
  `:SilverBulletSearch` or `:SilverBulletBacklinks` call. Building it requires
  downloading every Markdown page once, so the first lookup can be slow.
- The index is stored only in Neovim memory and is discarded when Neovim
  exits. Later lookups in the same session download only new or changed pages.

## Development

Run the unit, transport, and virtual-buffer tests with:

```sh
scripts/test
```

The test suite starts a local HTTP server and runs Neovim headlessly.

## License

[MIT](LICENSE)
