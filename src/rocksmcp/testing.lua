-- Drive a server in-process the way a client would, for specs:
--
--   local c = require("rocksmcp.testing").client(srv)
--   local r = c:call("search", { q = "x" })
--   assert(not r.isError, r.text)
--   assert(r.data.count == 3)
local json = require("rocksmcp.json")
local protocol = require("rocksmcp.protocol")
local server = require("rocksmcp.server")

local T = {}

---@class rocksmcp.TestResult
---@field content table[]
---@field structuredContent? table
---@field isError? boolean
---@field text string    every text block joined with newlines
---@field data any       text decoded as JSON, or nil when it is not JSON

---@class rocksmcp.TestClient
---@field session table      the engine session under test
---@field notifications table[]  every notification the server sent, in order
local Client = {}
Client.__index = Client

---@class rocksmcp.TestOpts
---@field init? boolean          run the initialize handshake (default true)
---@field capabilities? table    client capabilities sent at initialize
---@field protocol_version? string
---@field on_request? fun(method: string, params: table): any, table?  answers server-to-client requests (sampling, elicitation, roots): return result, or nil plus an error table

--- A fresh session on `srv`. Server notifications (srv:tools_changed() and the
--- like) go to this client from now on.
---@param srv table  a server from mcp.server
---@param opts? rocksmcp.TestOpts
---@return rocksmcp.TestClient
function T.client(srv, opts)
  opts = opts or {}
  local registry = srv.registry
  local session = protocol.new({
    info = srv.info,
    instructions = srv.instructions,
    capabilities = function() return server.capabilities(registry) end,
    methods = server.build_methods(registry),
  })
  srv._engine = session
  local c = setmetatable({
    session = session, notifications = {}, next_id = 0, on_request = opts.on_request,
  }, Client)
  if opts.init ~= false then
    c.initialize_result = c:request("initialize", {
      protocolVersion = opts.protocol_version or protocol.DEFAULT_VERSION,
      capabilities = opts.capabilities or json.object({}),
      clientInfo = { name = "rocksmcp.testing", version = "0" },
    }).result
    c:send({ jsonrpc = "2.0", method = "notifications/initialized" })
  end
  return c
end

-- feed one message; answer any server requests; return decoded responses
function Client:send(msg)
  local queue = { json.encode(msg) }
  local responses = {}
  while #queue > 0 do
    local line = table.remove(queue, 1)
    for _, out in ipairs(self.session:feed(line)) do
      local m = json.decode(out)
      if m.method and m.id ~= nil then
        local ok, result, err = false, nil, { code = -32601, message = "no on_request in the test client" }
        if self.on_request then
          ok, result, err = pcall(self.on_request, m.method, m.params)
          if not ok then result, err = nil, { code = -32603, message = tostring(result) } end
        end
        local reply = { jsonrpc = "2.0", id = m.id }
        if err then reply.error = err else reply.result = result or json.object({}) end
        queue[#queue + 1] = json.encode(reply)
      elseif m.method then
        self.notifications[#self.notifications + 1] = m
      else
        responses[#responses + 1] = m
      end
    end
  end
  return responses
end

--- Send a request; returns the raw JSON-RPC response ({ result } or { error }).
---@param method string
---@param params? table
---@return table
function Client:request(method, params)
  self.next_id = self.next_id + 1
  local id = self.next_id
  for _, m in ipairs(self:send({ jsonrpc = "2.0", id = id, method = method, params = params })) do
    if m.id == id then return m end
  end
  error(("no response to %s (id %d); did the handler yield outside a client request?"):format(method, id), 2)
end

--- Call a tool. Returns the tool result plus `text` and `data` for asserting.
--- A JSON-RPC error (unknown tool, a { code = ... } error) raises.
---@param name string
---@param args? table
---@return rocksmcp.TestResult
function Client:call(name, args)
  if args == nil or next(args) == nil then args = json.object({}) end
  local m = self:request("tools/call", { name = name, arguments = args })
  if m.error then
    error(("tools/call %s: JSON-RPC error %s: %s"):format(name, tostring(m.error.code), tostring(m.error.message)), 2)
  end
  local r = m.result
  local parts = {}
  for _, block in ipairs(r.content or {}) do
    if block.type == "text" then parts[#parts + 1] = block.text end
  end
  r.text = table.concat(parts, "\n")
  local ok, data = pcall(json.decode, r.text)
  if ok and data ~= json.null() then r.data = data end
  return r
end

--- Every tool, across all pages, as tools/list describes them.
---@return table[]
function Client:list_tools()
  local tools, cursor = {}, nil
  repeat
    local m = self:request("tools/list", { cursor = cursor })
    if m.error then error("tools/list: " .. tostring(m.error.message), 2) end
    for _, t in ipairs(m.result.tools) do tools[#tools + 1] = t end
    cursor = m.result.nextCursor
  until cursor == nil or cursor == json.null()
  return tools
end

--- The tools/list entry for one tool, or nil.
---@param name string
---@return table|nil
function Client:tool(name)
  for _, t in ipairs(self:list_tools()) do
    if t.name == name then return t end
  end
end

return T
