local protocol = require("rocksmcp.protocol")
local json = require("rocksmcp.json")

local M = {}

local PAGE = 50

-- shared cursor pagination over a materialized list
function M.paginate(list, cursor)
  local start = 1
  if cursor ~= nil then
    start = tonumber(cursor)
    if start == nil or start < 1 or start ~= math.floor(start)
        or tostring(math.floor(start)) ~= cursor then
      error({ code = -32602, message = "Invalid cursor" }, 0)
    end
  end
  local page = {}
  for i = start, math.min(start + PAGE - 1, #list) do
    page[#page + 1] = list[i]
  end
  local next_cursor
  if start + PAGE <= #list then
    next_cursor = tostring(start + PAGE)
  end
  return page, next_cursor
end

-- compile "scheme://x/{a}/{b}" into an anchored Lua pattern + capture names
function M.compile_template(tmpl)
  local names = {}
  for n in tmpl:gmatch("{(%w+)}") do
    names[#names + 1] = n
  end
  local escaped = tmpl:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
  local pattern = "^" .. escaped:gsub("{%w+}", "(.-)") .. "$"
  return pattern, names
end

local function match_template(def, uri)
  local caps = { uri:match(def.pattern) }
  if caps[1] == nil then return nil end
  local vars = {}
  for i, n in ipairs(def.var_names) do
    vars[n] = caps[i]
  end
  return vars
end

local function shape_contents(uri, mime, res)
  if type(res) == "table" then
    if res.contents ~= nil then return res end
    if res.text ~= nil or res.blob ~= nil then
      res.uri = res.uri or uri
      res.mimeType = res.mimeType or mime
      return { contents = json.array({ res }) }
    end
    error("resource read handler returned an unrecognized table", 0)
  end
  return { contents = json.array({ { uri = uri, mimeType = mime, text = tostring(res) } }) }
end

function M.capabilities(registry)
  local caps = { logging = json.object({}) }
  if next(registry.tools) ~= nil then
    caps.tools = { listChanged = true }
  end
  if next(registry.resources) ~= nil or #registry.template_order > 0 then
    caps.resources = { subscribe = true, listChanged = true }
  end
  if next(registry.prompts) ~= nil then
    caps.prompts = { listChanged = true }
  end
  if registry.completion then
    caps.completions = json.object({})
  end
  return caps
end

local function shape_tool_result(res)
  if type(res) == "table" and res.content ~= nil then
    return res
  end
  local text
  if type(res) == "string" then
    text = res
  elseif res == nil then
    text = json.encode(json.object({}))
  else
    text = json.encode(res)
  end
  return { content = json.array({ { type = "text", text = text } }) }
end

local function tool_error(id, err)
  if type(err) == "table" and err.code then
    return protocol.error_msg(id, err.code, err.message or "error", err.data)
  end
  return protocol.result_msg(id, {
    content = json.array({ { type = "text", text = tostring(err) } }),
    isError = true,
  })
end

function M.build_methods(registry)
  local methods = {}

  methods["tools/list"] = {
    run = function(params)
      local descs = {}
      for _, name in ipairs(registry.tool_order) do
        local t = registry.tools[name]
        descs[#descs + 1] = {
          name = t.name, description = t.description, inputSchema = t.input,
        }
      end
      local page, nxt = M.paginate(descs, params.cursor)
      return { tools = json.array(page), nextCursor = nxt }
    end,
  }

  methods["tools/call"] = {
    run = function(params, ctx)
      local tool = registry.tools[params.name]
      if not tool then
        error({ code = -32602, message = "Unknown tool: " .. tostring(params.name) }, 0)
      end
      local args = params.arguments
      if args == json.null() or args == nil then args = {} end
      return shape_tool_result(tool.handler(args, ctx))
    end,
    on_error = tool_error,
  }

  methods["resources/list"] = {
    run = function(params)
      local descs = {}
      for _, uri in ipairs(registry.resource_order) do
        local r = registry.resources[uri]
        descs[#descs + 1] = {
          uri = r.uri, name = r.name, description = r.description, mimeType = r.mime,
        }
      end
      local page, nxt = M.paginate(descs, params.cursor)
      return { resources = json.array(page), nextCursor = nxt }
    end,
  }

  methods["resources/templates/list"] = {
    run = function(params)
      local descs = {}
      for _, t in ipairs(registry.template_order) do
        descs[#descs + 1] = {
          uriTemplate = t.uri_template, name = t.name,
          description = t.description, mimeType = t.mime,
        }
      end
      local page, nxt = M.paginate(descs, params.cursor)
      return { resourceTemplates = json.array(page), nextCursor = nxt }
    end,
  }

  methods["resources/read"] = {
    run = function(params, ctx)
      local uri = params.uri
      if type(uri) ~= "string" then
        error({ code = -32602, message = "uri is required" }, 0)
      end
      local res = registry.resources[uri]
      if res then
        return shape_contents(uri, res.mime, res.read(uri, ctx))
      end
      for _, t in ipairs(registry.template_order) do
        local vars = match_template(t, uri)
        if vars then
          return shape_contents(uri, t.mime, t.read(uri, ctx, vars))
        end
      end
      error({ code = -32002, message = "Resource not found: " .. uri }, 0)
    end,
  }

  local function known_uri(uri)
    if registry.resources[uri] then return true end
    for _, t in ipairs(registry.template_order) do
      if match_template(t, uri) then return true end
    end
    return false
  end

  methods["resources/subscribe"] = {
    run = function(params)
      local uri = params.uri
      if type(uri) ~= "string" or not known_uri(uri) then
        error({ code = -32002, message = "Resource not found: " .. tostring(uri) }, 0)
      end
      registry.subscriptions[uri] = true
      return json.object({})
    end,
  }

  methods["resources/unsubscribe"] = {
    run = function(params)
      registry.subscriptions[params.uri] = nil
      return json.object({})
    end,
  }

  return methods
end

return M
