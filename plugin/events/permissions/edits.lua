vim.api.nvim_create_autocmd("User", {
  group = vim.api.nvim_create_augroup("OpencodeEdits", { clear = true }),
  pattern = { "OpencodeEvent:permission.asked", "OpencodeEvent:permission.replied" },
  callback = function(args)
    ---@type opencode.server.Event
    local event = args.data.event
    ---@type string
    local url = args.data.url

    local opts = require("opencode.config").opts.events.permissions or {}
    if not opts.enabled or not opts.edits.enabled then
      return
    end

    local Server = require("opencode.server")
    local server = Server.connected
        and Server.connected.url == url
        and require("opencode.promise").resolve(Server.connected)
      or Server.new(url, args.data.version, args.data.managed)
    server
      :next(function(server)
        local pending = event.type == "permission.asked"
            and require("opencode.events.permissions.pending").check(event, server)
          or require("opencode.promise").resolve(true)
        return pending:next(function(is_pending)
          if is_pending then
            return require("opencode.events.permissions.edits").diff(event):next(function(reply)
              if reply then
                return server:permit(event.properties.id, reply, event.properties.sessionID)
              end
            end)
          end
        end)
      end)
      :catch(function(err)
        if err then
          vim.notify("OpenCode edit request error: " .. err, vim.log.levels.ERROR, { title = "opencode" })
        end
      end)
  end,
  desc = "Diff proposed edits from OpenCode",
})
