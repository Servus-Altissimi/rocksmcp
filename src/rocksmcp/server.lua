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

  return methods
end

return M
