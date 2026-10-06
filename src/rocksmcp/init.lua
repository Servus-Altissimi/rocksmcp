local protocol = require("rocksmcp.protocol")
local server = require("rocksmcp.server")
local json = require("rocksmcp.json")

local mcp = {}

mcp.VERSION = "0.1.2"
mcp.schema = require("rocksmcp.schema")
mcp.json = json

---@param codec string|table  module name like "rocksmcp.json.cjson", or a codec table
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

--- Replace where diagnostics go (default: a line on stderr). Diagnostics are
--- tracebacks of crashed handlers and registration warnings; the client never
--- sees them. Returns the previous function.
---@param fn fun(message: string)
---@return fun(message: string)
function mcp.set_diagnostics(fn)
  assert(type(fn) == "function", "set_diagnostics takes a function(message)")
  local prev = protocol.diagnostics
  protocol.diagnostics = fn
  return prev
end

---@class rocksmcp.Result
---@field content? table[]          content blocks, e.g. { mcp.text("hi") }
---@field structuredContent? table  data matching the tool's output_schema
---@field isError? boolean

--- Mark a table as a complete MCP tool result, sent as-is. Any other table a
--- handler returns is data and gets JSON-encoded into a text block.
---@param r rocksmcp.Result
---@return rocksmcp.Result
function mcp.result(r)
  assert(type(r) == "table", "mcp.result takes a table { content = ..., structuredContent = ..., isError = ... }")
  if r.content ~= nil then
    assert(type(r.content) == "table", "mcp.result: content must be an array of content blocks")
    r.content = json.array(r.content)
  end
  return server.mark_result(r)
end

---@class rocksmcp.ServerOpts
---@field name string
---@field version string
---@field instructions? string       told to the client at initialize; say how to use the tools
---@field validate_input? boolean    check tool arguments against each input schema (default false)
---@field max_result_bytes? integer  refuse tool results whose text is larger (default no cap)

---@class rocksmcp.Ctx
---@field progress fun(progress: number, total?: number, message?: string): boolean
---@field log fun(level: string, message: string, data?: any): boolean
---@field sample fun(params: table): table
---@field elicit fun(params: table): table
---@field roots fun(): table[]
---@field cancelled fun(): boolean
---@field client table|nil

---@class rocksmcp.ToolDef
---@field name string
---@field description? string                the model's only manual for the tool
---@field input? rocksmcp.Schema             an object schema (mcp.schema.obj); default no arguments
---@field handler? fun(args: table, ctx: rocksmcp.Ctx): any
---@field actions? table<string, fun(args: table, ctx: rocksmcp.Ctx): any>  instead of handler: dispatch on args.action
---@field action_order? string[]             order of the action enum (default sorted)
---@field annotations? table                 readOnlyHint, destructiveHint, idempotentHint, openWorldHint, title
---@field output_schema? rocksmcp.Schema
---@field validate? boolean                  override the server's validate_input for this tool
---@field title? string

local Server = {}
Server.__index = Server

local SERVER_KEYS = { name = true, version = true, instructions = true, validate_input = true, max_result_bytes = true }

-- what people (and models) write by mistake, and what they meant
local HINTS = {
  inputSchema = "input", input_schema = "input", schema = "input", params = "input", parameters = "input",
  outputSchema = "output_schema", output = "output_schema",
  fn = "handler", run = "handler", call = "handler", callback = "handler", func = "handler",
  desc = "description", summary = "description",
}

local TOOL_KEYS = {
  name = true, description = true, input = true, handler = true, actions = true, action_order = true,
  annotations = true, output_schema = true, validate = true, title = true,
}

local function sorted_keys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = tostring(k) end
  table.sort(out)
  return out
end

-- one error naming every problem with a definition, raised at the caller
local function check_keys(what, def, allowed, problems)
  for _, k in ipairs(sorted_keys(def)) do
    if not allowed[k] then
      local hint = HINTS[k]
      problems[#problems + 1] = hint and ("unknown field '%s' (did you mean '%s'?)"):format(k, hint)
        or ("unknown field '%s' (allowed: %s)"):format(k, table.concat(sorted_keys(allowed), ", "))
    end
  end
end

local function raise(what, problems)
  if #problems > 0 then
    error(what .. ": " .. table.concat(problems, "; "), 3)
  end
end

---@param opts rocksmcp.ServerOpts
function mcp.server(opts)
  local problems = {}
  if type(opts) ~= "table" then
    error("mcp.server takes a table: mcp.server{ name = \"x\", version = \"1.0.0\" }", 2)
  end
  if type(opts.name) ~= "string" or opts.name == "" then problems[#problems + 1] = "name must be a non-empty string" end
  if opts.version == nil then problems[#problems + 1] = "version is required" end
  if opts.max_result_bytes ~= nil and (type(opts.max_result_bytes) ~= "number" or opts.max_result_bytes < 1) then
    problems[#problems + 1] = "max_result_bytes must be a positive number"
  end
  check_keys("mcp.server", opts, SERVER_KEYS, problems)
  raise("mcp.server", problems)
  return setmetatable({
    info = { name = opts.name, version = opts.version },
    instructions = opts.instructions,
    registry = {
      tools = {}, tool_order = {},
      resources = {}, resource_order = {},
      template_order = {},
      prompts = {}, prompt_order = {},
      completion = nil,
      -- per-server (single session); move into Session for multi-session transports
      subscriptions = {},
      validate_input = opts.validate_input == true,
      max_result_bytes = opts.max_result_bytes,
    },
    _engine = nil,
  }, Server)
end

-- the action enum a tool with `actions` takes, in order
local function action_names(def)
  if def.action_order then return def.action_order end
  return sorted_keys(def.actions)
end

local function with_action(input, names)
  local props = {}
  for k, v in pairs(input and input.properties or {}) do props[k] = v end
  props.action = mcp.schema.enum(names, "What to do")
  local required = { "action" }
  for _, r in ipairs(input and input.required or {}) do
    if r ~= "action" then required[#required + 1] = r end
  end
  local out = mcp.schema.obj(props, required, input and input.description)
  if input and input.additionalProperties ~= nil then out.additionalProperties = input.additionalProperties end
  return out
end

--- Register a tool. Fails at once, naming every problem, if the definition is
--- malformed. After a client is connected, call srv:tools_changed() if you add
--- tools late.
---@param def rocksmcp.ToolDef
function Server:tool(def)
  if type(def) ~= "table" then error("srv:tool takes a table { name, description, input, handler }", 2) end
  local problems = {}
  local label = "srv:tool " .. (type(def.name) == "string" and ("'" .. def.name .. "'") or "")
  if type(def.name) ~= "string" or def.name == "" then
    problems[#problems + 1] = "name must be a non-empty string"
  elseif not def.name:match("^[%w_%-%.]+$") or #def.name > 128 then
    problems[#problems + 1] = "name may only use letters, digits, _ - . (max 128)"
  elseif self.registry.tools[def.name] then
    problems[#problems + 1] = "a tool with this name is already registered"
  end
  if def.description ~= nil and type(def.description) ~= "string" then
    problems[#problems + 1] = "description must be a string"
  end
  if def.handler ~= nil and def.actions ~= nil then
    problems[#problems + 1] = "give handler or actions, not both"
  elseif def.actions ~= nil then
    if type(def.actions) ~= "table" or next(def.actions) == nil then
      problems[#problems + 1] = "actions must be a table of name = function"
    else
      for _, k in ipairs(sorted_keys(def.actions)) do
        if type(def.actions[k]) ~= "function" then problems[#problems + 1] = ("actions.%s must be a function"):format(k) end
      end
      for _, k in ipairs(def.action_order or {}) do
        if not def.actions[k] then problems[#problems + 1] = ("action_order names '%s', which has no function"):format(k) end
      end
      if def.action_order and #def.action_order ~= #sorted_keys(def.actions) then
        problems[#problems + 1] = "action_order must list every action exactly once"
      end
    end
  elseif type(def.handler) ~= "function" then
    problems[#problems + 1] = "handler must be a function(args, ctx)"
  end
  if def.input ~= nil and (type(def.input) ~= "table" or def.input.type ~= "object") then
    problems[#problems + 1] = "input must be an object schema, e.g. mcp.schema.obj({ q = mcp.schema.str() }, { \"q\" })"
  end
  if def.output_schema ~= nil and (type(def.output_schema) ~= "table" or def.output_schema.type ~= "object") then
    problems[#problems + 1] = "output_schema must be an object schema"
  end
  if def.annotations ~= nil and type(def.annotations) ~= "table" then
    problems[#problems + 1] = "annotations must be a table"
  end
  check_keys(label, def, TOOL_KEYS, problems)
  raise(label, problems)
  if def.description == nil or def.description == "" then
    protocol.diagnostics(label .. " has no description; the model will not know when or how to call it")
  end

  local t = {}
  for k, v in pairs(def) do t[k] = v end
  t.input = t.input or mcp.schema.obj({})
  if def.actions then
    local names = action_names(def)
    t.input = with_action(def.input, names)
    local actions = def.actions
    t.handler = function(args, ctx)
      local fn = actions[args.action]
      if not fn then
        error(("action must be one of: %s (got %s)"):format(table.concat(names, ", "), tostring(args.action)), 0)
      end
      return fn(args, ctx)
    end
  end
  if t.title and t.annotations == nil then t.annotations = { title = t.title } end
  self.registry.tools[t.name] = t
  local order = self.registry.tool_order
  order[#order + 1] = t.name
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

function Server:prompt(def)
  assert(type(def) == "table" and type(def.name) == "string" and def.name ~= ""
    and type(def.get) == "function", "prompt requires name (string) and get (function)")
  assert(not self.registry.prompts[def.name],
    "prompt already registered: " .. tostring(def.name))
  self.registry.prompts[def.name] = def
  local order = self.registry.prompt_order
  order[#order + 1] = def.name
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
