local M = {}

local function request(server, path, method, body)
  return require("opencode.promise").new(function(resolve, reject)
    server:curl(path, method, body, resolve, reject)
  end)
end

function M.get_health(server)
  return require("opencode.promise").new(function(resolve, reject)
    server:curl("/global/health", "GET", nil, resolve, function(msg, _, status)
      reject(status == 401 and ("Unauthorized response from OpenCode at " .. server:display_name()) or msg)
    end)
  end)
end

function M.append_prompt(server, text)
  return request(server, "/tui/publish", "POST", { type = "tui.prompt.append", properties = { text = text } })
end

function M.execute_command(server, command)
  return request(server, "/tui/publish", "POST", { type = "tui.command.execute", properties = { command = command } })
end

function M.permit(server, permission, reply)
  return request(server, "/permission/" .. permission .. "/reply", "POST", { reply = reply })
end

function M.get_permissions(server)
  return request(server, "/permission", "GET")
end

function M.get_agents(server)
  return request(server, "/agent", "GET")
end

function M.get_sessions(server)
  return request(server, "/session", "GET")
end

function M.select_session(server, session_id)
  return request(server, "/tui/select-session", "POST", { sessionID = session_id })
end

function M.get_path(server)
  return request(server, "/path", "GET")
end

function M.subscribe(server, on_success, on_error)
  return server:curl("/event", "GET", nil, on_success, on_error, { persistent = true })
end

return M
