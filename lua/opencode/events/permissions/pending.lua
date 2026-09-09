local M = {}
local replied = {}

local function key(server, id)
  return server.url .. ":" .. tostring(id)
end

---@param event opencode.server.Event | { type: "permission.replied" }
---@param server opencode.server.Server
function M.mark_replied(event, server)
  local request_key = key(server, event.properties.requestID)
  replied[request_key] = true
  vim.defer_fn(function()
    replied[request_key] = nil
  end, 1000)
end

---Wait briefly for OpenCode clients that automatically answer permission requests,
---then verify that the request is still pending before displaying UI.
---@param event opencode.server.Event | { type: "permission.asked" }
---@param server opencode.server.Server
---@return Promise<boolean>
function M.check(event, server)
  local Promise = require("opencode.promise")
  local request_key = key(server, event.properties.id)
  return Promise.new(function(resolve)
    vim.defer_fn(resolve, 100)
  end)
    :next(function()
      if replied[request_key] then
        return Promise.resolve({})
      end
      return server:get_permissions(event.properties.sessionID)
    end)
    :next(function(permissions)
      if replied[request_key] then
        return Promise.resolve(false)
      end
      for _, permission in ipairs(permissions) do
        if permission.id == event.properties.id then
          return Promise.resolve(true)
        end
      end
      return Promise.resolve(false)
    end)
    :catch(function()
      -- Preserve permission handling if a server version does not expose its pending list as expected.
      return Promise.resolve(true)
    end)
end

return M
