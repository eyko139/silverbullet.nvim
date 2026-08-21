local fs = require("silverbullet.client.fs")
local log = require("silverbullet.log")

local M = {}

function M.show_diff(buf, remote_content)
  local current_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_get_current_buf() ~= buf then
    vim.api.nvim_set_current_buf(buf)
  end
  vim.cmd("diffthis")
  vim.cmd("rightbelow vnew")
  local remote_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(remote_buf, "silverbullet-remote://" .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t"))
  vim.bo[remote_buf].buftype = "nofile"
  vim.bo[remote_buf].bufhidden = "wipe"
  vim.bo[remote_buf].swapfile = false
  vim.bo[remote_buf].filetype = "markdown"
  local lines = vim.split(remote_content, "\n", { plain = true })
  if remote_content:sub(-1) == "\n" then
    table.remove(lines)
  end
  vim.api.nvim_buf_set_lines(remote_buf, 0, -1, false, #lines > 0 and lines or { "" })
  vim.bo[remote_buf].modifiable = false
  vim.bo[remote_buf].modified = false
  vim.cmd("diffthis")
  vim.api.nvim_set_current_win(current_win)
end

function M.handle(buf, remote_content)
  vim.schedule(function()
    vim.ui.select({ "Show diff", "Reload remote", "Force overwrite", "Cancel" }, {
      prompt = "SilverBullet page changed remotely:",
    }, function(choice)
      if choice == "Show diff" then
        M.show_diff(buf, remote_content)
      elseif choice == "Reload remote" then
        require("silverbullet.buffer").reload(buf, true)
      elseif choice == "Force overwrite" then
        vim.ui.select({ "Force overwrite", "Cancel" }, {
          prompt = "Overwrite the remote page and discard its changes?",
        }, function(confirm)
          if confirm == "Force overwrite" then
            require("silverbullet.buffer").write(buf, { force = true })
          end
        end)
      end
    end)
  end)
end

function M.fetch_and_handle(buf, buffer_state)
  local remote, err = fs.read(buffer_state.space, buffer_state.path)
  if not remote then
    log.error(err)
    return
  end
  M.handle(buf, remote.content)
end

return M
