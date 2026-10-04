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

-- compile "scheme://x/{a}/{b}" into an anchored Lua pattern + capture names.
-- Matching uses lazy captures: the first variable takes the shortest match,
-- later variables absorb the remainder (differs from greedy RFC 6570).
function M.compile_template(tmpl)
  local names = {}
  for n in tmpl:gmatch("{([%w_]+)}") do
    names[#names + 1] = n
  end
  local seen = {}
  for _, n in ipairs(names) do
    if seen[n] then
      error("duplicate variable in uri_template: " .. n, 0)
    end
    seen[n] = true
  end
  local escaped = tmpl:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
  local pattern = "^" .. escaped:gsub("{[%w_]+}", "(.-)") .. "$"
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
      return { contents = json.array({ {
        uri = res.uri or uri,
        mimeType = res.mimeType or mime,
        text = res.text,
        blob = res.blob,
      } }) }
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

local function shape_tool_result(res, tool)
  if type(res) == "table" and (res.content ~= nil or res.structuredContent ~= nil) then
    if res.content == nil then
      res.content = json.array({ { type = "text", text = json.encode(res.structuredContent) } })
    end
    return res
  end
  if tool.output_schema and type(res) == "table" then
    return { content = json.array({ { type = "text", text = json.encode(res) } }), structuredContent = res }
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
          annotations = t.annotations, outputSchema = t.output_schema,
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
      return shape_tool_result(tool.handler(args, ctx), tool)
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
      if type(params.uri) ~= "string" then
        error({ code = -32602, message = "uri is required" }, 0)
      end
      registry.subscriptions[params.uri] = nil
      return json.object({})
    end,
  }

  methods["prompts/list"] = {
    run = function(params)
      local descs = {}
      for _, name in ipairs(registry.prompt_order) do
        local p = registry.prompts[name]
        local args
        if p.args and #p.args > 0 then
          args = {}
          for i, a in ipairs(p.args) do
            args[i] = {
              name = a.name, description = a.description,
              required = a.required or nil,
            }
          end
          args = json.array(args)
        end
        descs[#descs + 1] = {
          name = p.name, description = p.description, arguments = args,
        }
      end
      local page, nxt = M.paginate(descs, params.cursor)
      return { prompts = json.array(page), nextCursor = nxt }
    end,
  }

  methods["prompts/get"] = {
    run = function(params, ctx)
      local p = registry.prompts[params.name]
      if not p then
        error({ code = -32602, message = "Unknown prompt: " .. tostring(params.name) }, 0)
      end
      local args = params.arguments
      if args == json.null() or args == nil then args = {} end
      if type(args) ~= "table" then
        error({ code = -32602, message = "arguments must be a table" }, 0)
      end
      for _, a in ipairs(p.args or {}) do
        if a.required and args[a.name] == nil then
          error({ code = -32602, message = "Missing required argument: " .. a.name }, 0)
        end
      end
      local res = p.get(args, ctx)
      if type(res) ~= "table" or type(res.messages) ~= "table" then
        error("prompt get handler must return { messages = ... }", 0)
      end
      local msgs = {}
      for i = 1, #res.messages do msgs[i] = res.messages[i] end
      return {
        description = res.description or p.description,
        messages = json.array(msgs),
      }
    end,
  }

  methods["completion/complete"] = {
    run = function(params, ctx)
      if not registry.completion then
        error({ code = -32601, message = "Completions not supported" }, 0)
      end
      local res = registry.completion(params.ref, params.argument, ctx, params.context)
      local values, total, has_more
      if type(res) == "table" and res.values ~= nil then
        values, total, has_more = res.values, res.total, res.hasMore
      else
        values = res or {}
      end
      local capped = {}
      for i = 1, math.min(#values, 100) do
        capped[i] = values[i]
      end
      if has_more == nil and #values > 100 then has_more = true end
      return { completion = { values = json.array(capped), total = total, hasMore = has_more } }
    end,
  }

  return methods
end

return M
