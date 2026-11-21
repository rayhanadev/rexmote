-- Configuration for require("rexmote").setup{...} in Rex's init.lua.
local M = {}
local directions = {
  right = { "horizontal", "after" }, left = { "horizontal", "before" },
  below = { "vertical", "after" }, above = { "vertical", "before" },
}

function M.setup(options)
  local opts = options or {}
  local contents = opts.holder and opts.holder:match("^(.*)/Resources/[^/]+$")
    or (os.getenv("HOME") .. "/Applications/Rexmote.app/Contents")
  local cli = contents .. "/MacOS/rexmote"
  local where = directions[opts.split or "right"]
  local ratio = opts.ratio or 0.5
  if not where or type(ratio) ~= "number" or not (ratio > 0 and ratio < 1) then
    error("rexmote needs a split direction and a ratio between zero and one", 0)
  end
  local function remote_client(ctx)
    if ctx.server then
      -- A GUI action runs on the viewing Mac, with Rex API calls scoped to the selected server.
      local server = rex.call("server.status")
      if not server or not server.host_id then return false end
      local check = rex.exec({cli, "is-remote-server", server.host_id}, {timeout = 3})
      return check and check.ok
    end
    if not ctx.client_id then return false end
    local reply = rex.call("client.inspect", { client_id = ctx.client_id })
    local client = reply and (reply.client or reply)
    return client and client.principal and client.principal.transport == "tailscale"
  end

  local function desktop()
    -- Rex can build a remote layout on the viewing Mac. Expand HOME inside the new block on its session host.
    local command = opts.holder and { opts.holder }
      or { "/bin/sh", "-c", 'exec "$HOME/Applications/Rexmote.app/Contents/Resources/rexmote-pane"' }
    return rex.layout.block{
      flavor = "com.superlogical.terminal.shell", label = "Remote Desktop",
      options = { shell = "none", login = false, command = command },
    }
  end

  rex.action{
    name = "rexmote_panes", title = "List Remote Desktop Panes", category = "Remote Desktop",
    run = function(ctx)
      if not ctx.session_id then return "[]" end
      local result, err = rex.exec({cli, "registered-panes", ctx.session_id}, {timeout = 3})
      if not result then error(err, 0) end
      if not result.ok then error(result.stderr, 0) end
      return result.stdout
    end,
  }

  rex.action{
    name = "rexmote_open", title = "Open Remote Desktop Pane", category = "Remote Desktop",
    description = "Open this session’s Mac beside the current pane.",
    keywords = "rexmote remote screen desktop share mac",
    run = function(ctx)
      if not remote_client(ctx) then return end
      local result, err = rex.session.new_split{
        anchor_id = ctx.block_id, direction = where[1], side = where[2],
        ratio = where[2] == "after" and 1 - ratio or ratio,
        focus = true, layout = desktop(),
      }
      if err then error(err, 0) end
      return result
    end,
  }
  rex.action{
    name = "rexmote_open_tab", title = "Open Remote Desktop Tab", category = "Remote Desktop",
    description = "Open this session’s Mac in a new Rex tab.",
    run = function(ctx)
      if not remote_client(ctx) then return end
      local result, err = rex.session.new_window{ layout = desktop() }
      if err then error(err, 0) end
      if ctx.session_id and result.window_id then
        rex.client.queue("session.select", { session_id = ctx.session_id, window_id = result.window_id })
      end
      return result
    end,
  }
  if opts.key ~= false then rex.bind(opts.key or "shift+cmd+m", "rexmote_open") end
end

return M
