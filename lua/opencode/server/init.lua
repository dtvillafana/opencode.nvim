---@class opencode.server.Opts
---Full URL of an OpenCode server, e.g. `"http://localhost:4096"`.
---Bypasses local process discovery and connects directly.
---For version 1, you _must_ run `opencode` with the `--port` flag to expose its server.
---If pointing to a version 1 headless server, you _must_ attach a TUI via `opencode attach <URL>`.
---@field url? string | fun(callback: fun(url?: string))
---@field connect? boolean Whether to connect to an OpenCode server before interacting with it, listening for events and targeting it for future interactions.
---@field username? string Basic auth username.
---@field password? string Basic auth password.
---@field start? fun() | false Start an OpenCode server. Called when none are found; will retry after.

---An OpenCode server.
---@class opencode.server.Server
---@field url string
---@field cwd string
---@field title string
---@field subagents opencode.server.Agent[]
---@field version 1 | 2
---@field managed? boolean Whether OpenCode V2 manages this server and its authentication.
---@field username? string
---@field password? string
---@field session_id? string The selected OpenCode V2 session.
---@field subscription_job_id? number
---@field heartbeat_timer? uv.uv_timer_t
local Server = {}
Server.__index = Server

---Built-in OpenCode commands.
---@alias opencode.server.Command
---| 'agent.cycle'
---| 'prompt.clear'
---| 'prompt.submit'
---| 'session.compact'
---| 'session.first'
---| 'session.half.page.up'
---| 'session.half.page.down'
---| 'session.interrupt'
---| 'session.last'
---| 'session.new'
---| 'session.page.up'
---| 'session.page.down'
---| 'session.share'
---| 'session.redo'
---| 'session.undo'

---@class opencode.server.Session
---@field id string
---@field title string
---@field time { created: integer, updated: integer }

---@class opencode.server.Agent
---@field id? string
---@field name string
---@field description string
---@field mode "primary" | "subagent"

---@alias opencode.server.PermissionReply
---| "once"
---| "always"
---| "reject"

---Events emitted by OpenCode.
---Not exhaustive.
---@alias opencode.server.Event
---| { type: "file.edited" }
---| { type: "permission.asked", properties: { id: number | string, sessionID?: string, permission: string, patterns: string[], metadata?: { diff: string, filepath: string } } }
---| { type: "permission.replied", properties: { requestID: number | string, sessionID?: string } }
---| { type: "server.connected" }
---| { type: "server.instance.disposed" }
---| { type: "session.status", properties: { status: { type: "idle" | "busy" | "error" } } }
---| { type: "tui.command.execute", properties: { command: string } }
---| { type: string, properties: table }

---Attempt to connect to an OpenCode server and fetch its health and details.
---Rejects if the health fails — the last line of defense against false-positive server discovery.
---Rejection message is non-empty if from a valid OpenCode server.
---
---@param url string
---@param version? 1 | 2
---@param managed? boolean
---@param auth? { username?: string, password?: string }
---@return Promise<opencode.server.Server>
function Server.new(url, version, managed, auth)
  local self = setmetatable({}, Server)
  self.url = url:gsub("/$", "")
  local selected_version = version or require("opencode.config").opts.version
  self.version = selected_version == 2 and 2 or 1
  self.managed = managed
  self.username = auth and auth.username
  self.password = auth and auth.password
  self.heartbeat_timer = vim.uv.new_timer()

  local Promise = require("opencode.promise")
  -- Serially check health first to confirm that this is a valid and authenticated OpenCode server.
  -- Would like to differentiate headless servers, but not possible afaict unfortunately.
  -- No endpoint exposes such information, and TUI commands sent to a headless server with none attached just no-op, with no tell in the respone.
  -- So user must manually `opencode attach` in that case.
  return self
    :get_health()
    :next(function()
      return require("opencode.promise").all({
        self:get_path(),
        self:get_sessions(),
        self:get_agents(),
      })
    end)
    :next(
      function(results) ---@param results { [1]: { directory: string, worktree: string }, [2]: opencode.server.Session[], [3]: opencode.server.Agent }
        self.cwd = results[1].directory or results[1].worktree
        self.title = results[2][1] and results[2][1].title or "<No sessions>"
        self.session_id = self.version == 2 and results[2][1] and results[2][1].id or nil
        self.subagents = vim.tbl_filter(function(agent) ---@param agent opencode.server.Agent
          return agent.mode == "subagent"
        end, results[3])

        return Promise.resolve(self)
      end
    )
end

---Human-readable name, stripping the protocol prefix.
---
---@return string
function Server:display_name()
  local name = self.url:gsub("^%w+://", "")
  return name
end

---@param path string
---@param method "GET" | "POST"
---@param body table?
---@param on_success fun(response: table)
---@param on_error fun(msg: string, code: number, status: number?)
---@param opts? { persistent?: boolean }
---@return number job_id
function Server:curl(path, method, body, on_success, on_error, opts)
  local url = self.url .. path
  opts = opts or {
    persistent = false,
  }

  local cmd = {
    "curl",
    "-s", -- Silent
    "-S", -- Except for errors/stderr
    "--fail-with-body",
    "-X",
    method,
    "-H",
    "Content-Type: application/json",
    "-H",
    "Accept: application/json",
    "-H",
    "Accept: text/event-stream",
    "-N",
  }

  local username = self.username or require("opencode.config").opts.server.username
  local password = self.password or require("opencode.config").opts.server.password
  if username and password then
    -- We can always send credentials; servers with no auth set just ignore them
    table.insert(cmd, "--user")
    table.insert(cmd, username .. ":" .. password)
  end

  if not opts.persistent then
    table.insert(cmd, "--max-time")
    table.insert(cmd, 2)
  end

  if body then
    table.insert(cmd, "-d")
    table.insert(cmd, vim.fn.json_encode(body))
  end

  table.insert(cmd, url)

  local response_buffer = {}
  local function process_response_buffer()
    if #response_buffer > 0 then
      local full_event = table.concat(response_buffer)
      response_buffer = {}
      vim.schedule(function()
        if full_event == "" then
          on_success({})
          return
        end
        local ok, result = pcall(vim.fn.json_decode, full_event)
        if ok then
          if on_success then
            on_success(result)
          end
        else
          local error_message = "Failed to decode response from "
            .. url
            .. "\nResponse: "
            .. full_event
            .. "\nError: "
            .. result
          on_error(error_message, -1)
        end
      end)
    end
  end

  local stderr_lines = {}
  return vim.fn.jobstart(cmd, {
    on_stdout = function(_, data)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        if opts.persistent and (line:match("^event:") or line:match("^id:") or line:match("^:")) then
          -- SSE metadata; event payloads are carried in `data:` lines.
        elseif line == "" and opts.persistent then
          process_response_buffer()
        else
          local clean_line = (line:gsub("^data: ?", ""))
          table.insert(response_buffer, clean_line)
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stderr_lines, line)
          end
        end
      end
    end,
    on_exit = function(_, code)
      if code == 0 then
        process_response_buffer()
      else
        local response_message = #response_buffer > 0 and table.concat(response_buffer, "\n") or nil
        local stderr_message = #stderr_lines > 0 and table.concat(stderr_lines, "") or nil
        local status

        local detail_lines = { "Request to " .. url .. " failed with exit code: " .. code }
        if response_message and response_message ~= "" then
          table.insert(detail_lines, "Response:\n" .. response_message)
        end
        if stderr_message and stderr_message ~= "" then
          table.insert(detail_lines, "Stderr:\n" .. stderr_message)
          -- Afaict `curl` requires manual parsing of the response code one way or another regardless of flags :/
          status = stderr_message:match("The requested URL returned error: (%d+)$")
          status = tonumber(status)
        end

        local error_message = table.concat(detail_lines, "\n")
        on_error(error_message, code, status)
      end
    end,
  })
end

---@return Promise<any>
function Server:get_health()
  return require("opencode.api.v" .. self.version).get_health(self)
end

---@param text string
---@return Promise<any>
function Server:tui_append_prompt(text)
  return require("opencode.api.v" .. self.version).append_prompt(self, text)
end

---@param command opencode.server.Command | string
---@return Promise<any>
function Server:tui_execute_command(command)
  return require("opencode.api.v" .. self.version).execute_command(self, command)
end

---@param permission number | string
---@param reply opencode.server.PermissionReply
---@param session_id? string
---@return Promise<any>
function Server:permit(permission, reply, session_id)
  return require("opencode.api.v" .. self.version).permit(self, permission, reply, session_id)
end

---@param session_id? string
---@return Promise<table[]>
function Server:get_permissions(session_id)
  return require("opencode.api.v" .. self.version).get_permissions(self, session_id)
end

---@return Promise<opencode.server.Agent[]>
function Server:get_agents()
  return require("opencode.api.v" .. self.version).get_agents(self)
end

---@return Promise<opencode.server.Session[]>
function Server:get_sessions()
  return require("opencode.api.v" .. self.version).get_sessions(self)
end

---@param session_id string
---@return Promise<any>
function Server:select_session(session_id)
  return require("opencode.api.v" .. self.version).select_session(self, session_id)
end

---@return Promise<{ directory: string, worktree: string }>
function Server:get_path()
  return require("opencode.api.v" .. self.version).get_path(self)
end

---@param on_success fun(response: opencode.server.Event) Invoked with each received event.
---@param on_error fun(msg: string?, code: number)
---@return number job_id
function Server:sse_subscribe(on_success, on_error)
  return require("opencode.api.v" .. self.version).subscribe(self, on_success, on_error)
end

---How often OpenCode sends heartbeat events.
local OPENCODE_HEARTBEAT_INTERVAL_MS = 10000

---The currently connected server.
---Cleared when the server disposes itself, the connection errors, or the heartbeat disappears.
---@type opencode.server.Server?
Server.connected = nil

---Subscribe to this server's SSE stream and dispatch autocmds for received events.
---Disconnects currently connected server first.
---Idempotent.
---
---@return Promise<opencode.server.Server> server Promise that resolves or rejects according to initial connection success.
function Server:connect()
  local Promise = require("opencode.promise")

  if Server.connected == self then
    return Promise.resolve(self)
  elseif Server.connected then
    Server.connected:disconnect()
  end

  return Promise.new(function(resolve, reject)
    self.subscription_job_id = self:sse_subscribe(
      function(response)
        if self.heartbeat_timer and self.version == 1 then
          self.heartbeat_timer:start(
            OPENCODE_HEARTBEAT_INTERVAL_MS + 1000,
            0,
            vim.schedule_wrap(function()
              self:disconnect()
            end)
          )
        end

        if response.type == "server.connected" then
          Server.connected = self
          resolve(self)
        elseif response.type == "server.instance.disposed" then
          self:disconnect()
        end

        local same_location = not response.location
          or not response.location.directory
          or response.location.directory == self.cwd
        local session_id = response.properties and response.properties.sessionID
        local same_session = response.type ~= "session.status" or not session_id or session_id == self.session_id
        if self.version == 1 or (same_location and same_session) then
          require("opencode.events").emit(response, self)
        end
      end,
      -- Server disappeared ungracefully, e.g. process killed, network error, etc.
      -- Also called on manual disconnects, like our `vim.fn.jobstop`.
      function(msg)
        local was_connected = Server.connected == self
        self:disconnect()
        if not was_connected then
          reject(msg)
        end
      end
    )

    if self.version == 2 and not self.password and self.subscription_job_id > 0 then
      Server.connected = self
      local event = { type = "server.connected", properties = {} }
      require("opencode.events").emit(event, self)
      resolve(self)
    end
  end)
end

---Unsubscribe from this server's SSE stream and stop the heartbeat timer.
---Idempotent.
function Server:disconnect()
  if self.subscription_job_id then
    vim.fn.jobstop(self.subscription_job_id)
    self.subscription_job_id = nil
  end
  if self.heartbeat_timer then
    self.heartbeat_timer:stop()
  end

  if Server.connected == self then
    Server.connected = nil
    require("opencode.events.status").reset()
  end
end

return Server
