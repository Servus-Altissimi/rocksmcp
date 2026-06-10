local json = require("rocksmcp.json")

local M = {}

M.SUPPORTED_VERSIONS = { ["2025-06-18"] = true, ["2025-03-26"] = true }
M.DEFAULT_VERSION = "2025-06-18"

M.LOG_RANK = {
  debug = 1, info = 2, notice = 3, warning = 4,
  error = 5, critical = 6, alert = 7, emergency = 8,
}

function M.result_msg(id, result)
  return { jsonrpc = "2.0", id = id, result = result }
end

function M.error_msg(id, code, message, data)
  return { jsonrpc = "2.0", id = id, error = { code = code, message = message, data = data } }
end

-- strip "path/to/file.lua:NN: " prefixes from handler errors
function M.clean_err(e)
  if type(e) == "string" then
    return (e:gsub("^.-%.lua:%d+: ", ""))
  end
  return e
end

local function reqkey(id)
  return type(id) .. ":" .. tostring(id)
end

local Session = {}
Session.__index = Session

-- opts: info {name,version}, instructions?, capabilities (function -> table),
--       methods { [name] = def } where def = { run = f(params, ctx) -> result,
--       on_error = f(id, err) -> response msg (optional) }
function M.new(opts)
  return setmetatable({
    info = opts.info,
    instructions = opts.instructions,
    get_capabilities = opts.capabilities,
    methods = opts.methods or {},
    initialized = false,
    ready = false,
    client = nil,
    log_level = "debug",
    inflight = {},
    pending_out = {},
    next_out_id = 0,
    negotiated_version = nil,
    current_entry = nil,
    out = {},
  }, Session)
end

function Session:queue(msg)
  self.out[#self.out + 1] = json.encode(msg)
end

function Session:notify(method, params)
  self:queue({ jsonrpc = "2.0", method = method, params = params })
end

function Session:take_output()
  local o = self.out
  self.out = {}
  return o
end

local function default_on_error(id, err)
  if type(err) == "table" and err.code then
    return M.error_msg(id, err.code, err.message or "error", err.data)
  end
  return M.error_msg(id, -32603, tostring(err))
end

-- resume an entry's coroutine; emit its response when it completes
function Session:step(entry, ...)
  self.current_entry = entry
  local ok, res = coroutine.resume(entry.co, ...)
  self.current_entry = nil
  if ok and coroutine.status(entry.co) == "suspended" then
    if entry.awaiting then
      return -- parked awaiting a client response
    end
    -- handler yielded outside client_request: unrecoverable, fail the request
    self.inflight[entry.key] = nil
    self:queue((entry.on_error or default_on_error)(entry.id,
      "handler yielded outside of a client request"))
    return
  end
  self.inflight[entry.key] = nil
  if entry.cancelled then return end -- spec: no response after cancellation
  if ok then
    if res == nil then res = json.object({}) end
    self:queue(M.result_msg(entry.id, res))
  else
    local handler = entry.on_error or default_on_error
    self:queue(handler(entry.id, M.clean_err(res)))
  end
end

-- send a request to the client and park until its response arrives.
-- Must be called from inside a request coroutine.
function Session:client_request(method, params)
  local entry = self.current_entry
  if not entry or coroutine.running() ~= entry.co then
    error("client requests are only allowed inside a request handler", 0)
  end
  self.next_out_id = self.next_out_id + 1
  local id = self.next_out_id
  self.pending_out[id] = entry
  entry.awaiting = true
  self:queue({ jsonrpc = "2.0", id = id, method = method, params = params })
  local result, err = coroutine.yield()
  entry.awaiting = false
  if err ~= nil then
    error("client returned error for " .. method .. ": "
      .. tostring(type(err) == "table" and err.message or err), 0)
  end
  return result
end

function Session:make_ctx(params)
  local session = self
  local meta = type(params) == "table" and type(params._meta) == "table" and params._meta or {}
  local token = meta.progressToken
  local ctx = { client = nil, _cancelled = false }

  function ctx.progress(progress, total, message)
    if token == nil then return false end
    session:notify("notifications/progress", {
      progressToken = token, progress = progress, total = total, message = message,
    })
    return true
  end

  function ctx.log(level, message, data)
    local rank = M.LOG_RANK[level]
    if not rank then error("unknown log level: " .. tostring(level), 0) end
    if rank < (M.LOG_RANK[session.log_level] or 1) then return false end
    session:notify("notifications/message", {
      level = level,
      data = data ~= nil and { message = message, data = data } or message,
    })
    return true
  end

  function ctx.cancelled()
    return ctx._cancelled == true
  end

  local function gated(cap_key, method)
    return function(req_params)
      local caps = (session.client and session.client.capabilities) or {}
      local cap = caps[cap_key]
      if cap == nil or cap == json.null() then
        error("client does not support " .. cap_key, 0)
      end
      return session:client_request(method, req_params)
    end
  end

  ctx.sample = gated("sampling", "sampling/createMessage")
  ctx.elicit = gated("elicitation", "elicitation/create")
  local roots_req = gated("roots", "roots/list")
  function ctx.roots()
    local res = roots_req(json.object({}))
    return (res or {}).roots or {}
  end

  ctx.client = session.client
  return ctx
end

function Session:handle_response(msg)
  local entry = self.pending_out[msg.id]
  if not entry then return end
  self.pending_out[msg.id] = nil
  local err = msg.error
  if err == json.null() then err = nil end
  local result = msg.result
  if result == json.null() then result = nil end
  if err ~= nil then
    self:step(entry, nil, err)
  else
    self:step(entry, result, nil)
  end
end

function Session:handle_message(msg)
  local method, id = msg.method, msg.id
  local params = msg.params
  if params == json.null() then params = nil end
  params = params or {}

  -- notifications
  if id == nil then
    if method == "notifications/cancelled" then
      local entry = params.requestId ~= nil and self.inflight[reqkey(params.requestId)] or nil
      if entry then
        entry.cancelled = true
        if entry.ctx then entry.ctx._cancelled = true end
        -- if parked on a client request, cancel it and release the entry
        for out_id, parked in pairs(self.pending_out) do
          if parked == entry then
            self.pending_out[out_id] = nil
            self:notify("notifications/cancelled", { requestId = out_id })
            self.inflight[entry.key] = nil
            -- do not resume: the coroutine is abandoned; response already suppressed
          end
        end
      end
      return
    elseif method == "notifications/initialized" then
      self.ready = true
    end
    return -- all other notifications ignored
  end

  -- requests
  if method == "ping" then
    self:queue(M.result_msg(id, json.object({})))
    return
  end

  if method == "initialize" then
    if self.initialized then
      self:queue(M.error_msg(id, -32600, "Server already initialized"))
      return
    end
    self.initialized = true
    self.client = {
      info = params.clientInfo,
      capabilities = params.capabilities or {},
      protocolVersion = params.protocolVersion,
    }
    local v = M.SUPPORTED_VERSIONS[params.protocolVersion]
      and params.protocolVersion or M.DEFAULT_VERSION
    self.negotiated_version = v
    self:queue(M.result_msg(id, {
      protocolVersion = v,
      capabilities = self.get_capabilities and self.get_capabilities() or json.object({}),
      serverInfo = self.info,
      instructions = self.instructions,
    }))
    return
  end

  if not self.initialized then
    self:queue(M.error_msg(id, -32002, "Server not initialized"))
    return
  end

  if method == "logging/setLevel" then
    if M.LOG_RANK[params.level] then
      self.log_level = params.level
      self:queue(M.result_msg(id, json.object({})))
    else
      self:queue(M.error_msg(id, -32602, "Unknown log level: " .. tostring(params.level)))
    end
    return
  end

  local def = self.methods[method]
  if not def then
    self:queue(M.error_msg(id, -32601, "Method not found: " .. tostring(method)))
    return
  end

  local key = reqkey(id)
  if self.inflight[key] then
    self:queue(M.error_msg(id, -32600, "Duplicate request id: " .. tostring(id)))
    return
  end

  local ctx = self:make_ctx(params)
  local entry = {
    id = id,
    key = key,
    ctx = ctx,
    on_error = def.on_error,
    cancelled = false,
  }
  entry.co = coroutine.create(function()
    return def.run(params, ctx)
  end)
  self.inflight[entry.key] = entry
  self:step(entry)
end

function Session:feed(line)
  local msg, decode_err = json.decode(line)
  if msg == nil or msg == json.null() then
    self:queue(M.error_msg(json.null(), -32700, "Parse error"))
    return self:take_output()
  end
  if type(msg) ~= "table" then
    self:queue(M.error_msg(json.null(), -32600, "Invalid request"))
    return self:take_output()
  end
  if msg[1] ~= nil then
    self:queue(M.error_msg(json.null(), -32600, "Batch requests not supported"))
    return self:take_output()
  end
  if msg.method ~= nil then
    self:handle_message(msg)
  elseif msg.id ~= nil then
    self:handle_response(msg)
  end
  return self:take_output()
end

return M
