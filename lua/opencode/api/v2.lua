local M = {}
local decode

local function service_auth(url)
  local state_home = vim.env.XDG_STATE_HOME or (vim.env.HOME and vim.fs.joinpath(vim.env.HOME, ".local", "state"))
  if not state_home then
    return nil
  end
  local file = io.open(vim.fs.joinpath(state_home, "opencode", "service.json"), "r")
  if not file then
    return nil
  end
  local contents = file:read("*a")
  file:close()
  local ok, service = pcall(vim.fn.json_decode, contents)
  if not ok or service.url ~= url or type(service.password) ~= "string" then
    return nil
  end
  return { username = "opencode", password = service.password }
end

function M.discover()
  local Promise = require("opencode.promise")
  return Promise.new(function(resolve, reject)
    local ok, err = pcall(function()
      vim.system({ "opencode2", "api", "get", "/api/server" }, { text = true }, function(result)
        vim.schedule(function()
          if result.code ~= 0 then
            reject(string.format("`opencode2 api` failed with code %d\n%s", result.code, result.stderr or ""))
            return
          end
          local decoded, response = pcall(decode, result.stdout)
          if not decoded then
            reject(response)
            return
          end
          local servers = {}
          for _, url in ipairs(response.urls or {}) do
            table.insert(servers, require("opencode.server").new(url, 2, true, service_auth(url)))
          end
          Promise.all_settled(servers):next(function(results)
            local connected = {}
            for _, item in ipairs(results) do
              if item.status == "fulfilled" then
                table.insert(connected, item.value)
              end
            end
            if #connected == 0 then
              reject("No OpenCode V2 server found")
            else
              resolve(connected)
            end
          end)
        end)
      end)
    end)
    if not ok then
      reject("Failed to call `opencode2 api`: " .. err)
    end
  end)
end

decode = function(stdout)
  if not stdout or vim.trim(stdout) == "" then
    return {}
  end
  local ok, value = pcall(vim.fn.json_decode, stdout)
  if not ok then
    error("Failed to decode OpenCode V2 response: " .. value)
  end
  return value
end

local function cli_command(server, method, path, body)
  local command = { "opencode2", "api" }
  if not server.managed then
    vim.list_extend(command, { "--server", server.url })
  end
  vim.list_extend(command, { method:lower(), path })
  if body then
    vim.list_extend(command, { "--data", vim.fn.json_encode(body) })
  end
  return command
end

local function request(server, path, method, body)
  if server.password or not server.managed then
    return require("opencode.promise").new(function(resolve, reject)
      server:curl(path, method, body, resolve, reject)
    end)
  end

  return require("opencode.promise").new(function(resolve, reject)
    local ok, err = pcall(function()
      vim.system(cli_command(server, method, path, body), { text = true }, function(result)
        vim.schedule(function()
          if result.code ~= 0 then
            reject(string.format("`opencode2 api` failed with code %d\n%s", result.code, result.stderr or ""))
            return
          end
          local decoded, value = pcall(decode, result.stdout)
          if decoded then
            resolve(value)
          else
            reject(value)
          end
        end)
      end)
    end)
    if not ok then
      reject("Failed to call `opencode2 api`: " .. err)
    end
  end)
end

local function session(server)
  local Promise = require("opencode.promise")
  if server.session_id then
    return Promise.resolve(server.session_id)
  end
  return M.get_sessions(server):next(function(sessions)
    if sessions[1] then
      server.session_id = sessions[1].id
      return Promise.resolve(server.session_id)
    end
    return request(server, "/api/session", "POST", { location = { directory = vim.fn.getcwd() } }):next(
      function(response)
        server.session_id = response.data.id
        return Promise.resolve(server.session_id)
      end
    )
  end)
end

function M.get_health(server)
  return request(server, "/api/health", "GET")
end

function M.append_prompt()
  return require("opencode.promise").reject("OpenCode V2 cannot append text to a terminal prompt without submitting it")
end

function M.prompt(server, text)
  return session(server):next(function(session_id)
    return request(server, "/api/session/" .. session_id .. "/prompt", "POST", { text = text })
  end)
end

local unsupported = {
  ["prompt.clear"] = true,
  ["prompt.submit"] = true,
  ["session.first"] = true,
  ["session.half.page.up"] = true,
  ["session.half.page.down"] = true,
  ["session.last"] = true,
  ["session.page.up"] = true,
  ["session.page.down"] = true,
  ["session.redo"] = true,
  ["session.share"] = true,
  ["session.undo"] = true,
}

function M.execute_command(server, command)
  if unsupported[command] then
    return require("opencode.promise").reject("OpenCode V2 has no API equivalent for TUI command `" .. command .. "`")
  end
  if command == "session.new" then
    return request(server, "/api/session", "POST", { location = { directory = vim.fn.getcwd() } }):next(
      function(response)
        server.session_id = response.data.id
        return response
      end
    )
  end
  return session(server):next(function(session_id)
    if command == "session.compact" then
      return request(server, "/api/session/" .. session_id .. "/compact", "POST", {})
    elseif command == "session.interrupt" then
      return request(server, "/api/session/" .. session_id .. "/interrupt", "POST")
    elseif command == "agent.cycle" then
      return require("opencode.promise")
        .all({
          request(server, "/api/session/" .. session_id, "GET"),
          M.get_agents(server),
        })
        :next(function(results) ---@param results { [1]: { data: { agent?: string } }, [2]: opencode.server.Agent[] }
          local current = results[1].data.agent
          local agents = vim.tbl_filter(function(agent)
            return agent.mode == "primary" or agent.mode == "all"
          end, results[2])
          for index, agent in ipairs(agents) do
            if agent.id == current then
              local next_agent = agents[(index % #agents) + 1]
              return request(server, "/api/session/" .. session_id .. "/agent", "POST", { agent = next_agent.id })
            end
          end
          return #agents > 0
              and request(server, "/api/session/" .. session_id .. "/agent", "POST", { agent = agents[1].id })
            or require("opencode.promise").reject("No OpenCode V2 primary agents found")
        end)
    end
    return require("opencode.promise").reject("Unknown OpenCode V2 command `" .. command .. "`")
  end)
end

function M.permit(server, permission, reply, session_id)
  return session_id
      and request(
        server,
        "/api/session/" .. session_id .. "/permission/" .. permission .. "/reply",
        "POST",
        { reply = reply }
      )
    or require("opencode.promise").reject("OpenCode V2 permission event did not include a session ID")
end

function M.get_permissions(server, session_id)
  if not session_id then
    return require("opencode.promise").reject("OpenCode V2 permission event did not include a session ID")
  end
  return request(server, "/api/session/" .. session_id .. "/permission", "GET"):next(function(response)
    return response.data
  end)
end

function M.get_agents(server)
  return request(server, "/api/agent?location%5Bdirectory%5D=" .. vim.uri_encode(vim.fn.getcwd()), "GET"):next(
    function(response)
      return response.data
    end
  )
end

function M.get_sessions(server)
  local path = "/api/session?order=desc&directory=" .. vim.uri_encode(vim.fn.getcwd())
  return request(server, path, "GET"):next(function(response)
    return response.data
  end)
end

function M.select_session(server, session_id)
  server.session_id = session_id
  return require("opencode.promise").resolve(session_id)
end

function M.get_path()
  return require("opencode.promise").resolve({ directory = vim.fn.getcwd(), worktree = vim.fn.getcwd() })
end

local function normalize_event(value)
  while type(value) == "string" do
    local ok, decoded = pcall(vim.fn.json_decode, value)
    if not ok then
      return nil
    end
    value = decoded
  end
  if value.data and type(value.data) == "string" then
    return normalize_event(value.data)
  end
  if not value.type then
    return nil
  end
  value.properties = value.properties or value.data or {}
  if value.type == "permission.asked" then
    value.properties.permission = value.properties.permission or value.properties.action
    value.properties.patterns = value.properties.patterns or value.properties.resources or {}
  elseif value.type == "global.disposed" then
    value.type = "server.instance.disposed"
  elseif value.type == "session.error" then
    value.type = "session.status"
    value.properties.status = { type = "error" }
  end
  return value
end

function M.subscribe(server, on_success, on_error)
  if server.password or not server.managed then
    return server:curl("/api/event", "GET", nil, function(value)
      local event = normalize_event(value)
      if event then
        on_success(event)
      end
    end, on_error, { persistent = true })
  end

  local buffer = {}
  local function process(line)
    line = line:gsub("^data: ?", "")
    if line == "" or line:match("^:") or line:match("^event:") or line:match("^id:") then
      return
    end
    local ok, value = pcall(vim.fn.json_decode, line)
    local event = ok and normalize_event(value) or nil
    if event then
      vim.schedule(function()
        on_success(event)
      end)
    else
      table.insert(buffer, line)
    end
  end

  return vim.fn.jobstart(cli_command(server, "GET", "/api/event"), {
    pty = true,
    stdout_buffered = false,
    on_stdout = function(_, data)
      for _, line in ipairs(data or {}) do
        process(line)
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= "" then
          table.insert(buffer, line)
        end
      end
    end,
    on_exit = function(_, code)
      on_error(#buffer > 0 and table.concat(buffer, "\n") or nil, code)
    end,
  })
end

return M
