local protocol = require("rocksmcp.protocol")
local server = require("rocksmcp.server")
local json = require("rocksmcp.json")

local mcp = {}

mcp.schema = require("rocksmcp.schema")
mcp.json = json

function mcp.use_json(codec)
  return json.use(codec)
end

-- content helpers
function mcp.text(s)
  return { type = "text", text = s }
end

function mcp.user_text(s)
  return { role = "user", content = mcp.text(s) }
end

function mcp.assistant_text(s)
  return { role = "assistant", content = mcp.text(s) }
end

local Server = {}
Server.__index = Server

function mcp.server(opts)
  assert(type(opts) == "table" and type(opts.name) == "string" and opts.name ~= ""
    and opts.version, "mcp.server requires { name = ..., version = ... }")
  return setmetatable({
    info = { name = opts.name, version = opts.version },
    instructions = opts.instructions,
    registry = {
      tools = {}, tool_order = {},
      resources = {}, resource_order = {},
      template_order = {},
      prompts = {}, prompt_order = {},
      completion = nil,
      subscriptions = {},
    },
    _engine = nil,
  }, Server)
end

-- After a client is connected, call srv:tools_changed() if you add tools late.
function Server:tool(def)
  assert(type(def) == "table" and type(def.name) == "string" and def.name ~= ""
    and def.handler and def.input, "tool requires name (string), input, handler")
  assert(not self.registry.tools[def.name],
    "tool already registered: " .. tostring(def.name))
  self.registry.tools[def.name] = def
  local order = self.registry.tool_order
  order[#order + 1] = def.name
  return self
end

function Server:resource(def)
  assert(type(def) == "table" and def.uri and def.name and def.read,
    "resource requires uri, name, read")
  assert(not self.registry.resources[def.uri],
    "resource already registered: " .. tostring(def.uri))
  self.registry.resources[def.uri] = def
  local order = self.registry.resource_order
  order[#order + 1] = def.uri
  return self
end

function Server:resource_template(def)
  assert(type(def) == "table" and def.uri_template and def.name and def.read,
    "resource_template requires uri_template, name, read")
  local server_mod = require("rocksmcp.server")
  local tdef = {
    uri_template = def.uri_template,
    name = def.name,
    description = def.description,
    mime = def.mime,
    read = def.read,
  }
  tdef.pattern, tdef.var_names = server_mod.compile_template(def.uri_template)
  local order = self.registry.template_order
  order[#order + 1] = tdef
  return self
end

function Server:completion(fn)
  assert(type(fn) == "function", "completion requires a function")
  self.registry.completion = fn
  return self
end

function Server:engine()
  if not self._engine then
    local registry = self.registry
    self._engine = protocol.new({
      info = self.info,
      instructions = self.instructions,
      capabilities = function() return server.capabilities(registry) end,
      methods = server.build_methods(registry),
    })
  end
  return self._engine
end

function Server:notify(method, params)
  self:engine():notify(method, params)
end

function Server:tools_changed()
  self:notify("notifications/tools/list_changed", nil)
end

function Server:resources_changed()
  self:notify("notifications/resources/list_changed", nil)
end

function Server:prompts_changed()
  self:notify("notifications/prompts/list_changed", nil)
end

function Server:resource_updated(uri)
  if self.registry.subscriptions[uri] then
    self:notify("notifications/resources/updated", { uri = uri })
  end
end

function Server:run()
  require("rocksmcp.transport.stdio").run(self:engine())
end

return mcp
