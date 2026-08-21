# silverbullet.nvim

Edit a remote [SilverBullet](https://silverbullet.md) space as a native Neovim
Markdown workspace.

Pages open in normal buffers, `:write` saves them to SilverBullet, wiki links
remain navigable, and concurrent browser edits are detected before they can be
overwritten.

## Features

- Open, create, edit, reload, and delete remote Markdown pages
- Use normal Neovim buffers and `:write`
- Browse pages with a dependency-free `vim.ui.select()` picker
- Follow `[[Page]]`, `[[Page|Alias]]`, and `[[Page#Heading]]` links
- Detect remote changes with ETags or a SilverBullet 2.9-compatible fallback
- Open the current page in a browser
- Complete page names inside wiki links with the built-in omnifunc
- Connect to multiple named SilverBullet spaces
- Resolve credentials only when making a request
- Diagnose configuration, authentication, proxy, and connectivity problems
  with `:checkhealth silverbullet`
- Use only core Neovim APIs and `curl`; no plugin dependencies are required

## Requirements

- Neovim 0.10 or newer
- SilverBullet 2.9 or newer
- `curl` available on `PATH`

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

Do not place a SilverBullet token directly in your Neovim configuration.
Literal token strings are rejected.

### Environment variable

```lua
auth = {
  token_env = "SILVERBULLET_TOKEN",
}
```

Set the variable before starting Neovim:

```sh
export SILVERBULLET_TOKEN="your-token"
```

### Lua callback

```lua
auth = {
  token = function()
    return require("my_secrets").silverbullet_token()
  end,
}
```

### External command

```lua
auth = {
  command = { "op", "read", "op://Personal/SilverBullet/token" },
}
```

The command must print the token to standard output.

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
  },

  conflict = {
    check_on_focus = true,
    check_before_write = true,
  },

  picker = {
    provider = "auto",
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
| `:SilverBulletFind` | Select and open a page |
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
vim.keymap.set("n", "<CR>", "<Plug>(SilverBulletFollowLink)")
vim.keymap.set("n", "<leader>so", "<Plug>(SilverBulletOpenWeb)")
```

### Completion

Page completion is available inside `[[...]]` through Neovim's omnifunc:

```text
<C-x><C-o>
```

## Conflict protection

On servers that return ETags, existing pages are written with `If-Match` and
new pages with `If-None-Match`. A stale write is rejected by the server.

SilverBullet 2.9 does not support atomic conditional writes. In that case, the
plugin fetches the current remote content immediately before saving and
compares it with the version originally opened in Neovim. This prevents
detected overwrites but retains a small time-of-check/time-of-use race.

When a conflict is found, the plugin can:

- Show a diff against the remote page
- Reload the remote page
- Force an overwrite after a second confirmation
- Cancel and preserve local changes

Failed writes never clear the buffer's `modified` state.

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

## Development

Run the unit, transport, and virtual-buffer tests with:

```sh
scripts/test
```

The test suite starts a local HTTP server and runs Neovim headlessly.

## License

[MIT](LICENSE)
