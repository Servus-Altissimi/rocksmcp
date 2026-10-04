local mcp = require("rocksmcp")
local json = require("rocksmcp.json")
local H = require("spec.helper")

local function demo_server()
  local srv = mcp.server{ name = "demo", version = "1.0.0" }
  srv:tool{
    name = "greet", description = "Say hello",
    input = mcp.schema.obj({ who = mcp.schema.str("Name") }, { "who" }),
    handler = function(args) return { text = "hello " .. args.who } end,
  }
  srv:tool{
    name = "shout", description = "Return a string",
    input = mcp.schema.obj({}, {}),
    handler = function() return "AAH" end,
  }
  srv:tool{
    name = "boom", description = "Fails",
    input = mcp.schema.obj({}, {}),
    handler = function() error("kaboom", 0) end,
  }
  return srv
end

describe("tools", function()
  it("advertises tools capability with listChanged", function()
    local srv = demo_server()
    local res = H.init(srv:engine())
    assert.is_true(res.capabilities.tools.listChanged)
  end)

  it("lists tools in registration order with schemas", function()
    local srv = demo_server()
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/list" })
    local tools = r[1].result.tools
    assert.equal(3, #tools)
    assert.equal("greet", tools[1].name)
    assert.same({ "who" }, tools[1].inputSchema.required)
    assert.is_nil(r[1].result.nextCursor)
  end)

  it("paginates past 50 tools", function()
    local srv = mcp.server{ name = "many", version = "0" }
    for i = 1, 60 do
      srv:tool{ name = "t" .. i, description = "d",
        input = mcp.schema.obj({}, {}), handler = function() return "x" end }
    end
    local e = srv:engine()
    H.init(e)
    local p1 = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/list" })[1].result
    assert.equal(50, #p1.tools)
    assert.is_string(p1.nextCursor)
    local p2 = H.rpc(e, { jsonrpc = "2.0", id = 3, method = "tools/list",
      params = { cursor = p1.nextCursor } })[1].result
    assert.equal(10, #p2.tools)
    assert.is_nil(p2.nextCursor)
    assert.equal("t51", p2.tools[1].name)
  end)

  it("rejects invalid cursors", function()
    local srv = demo_server()
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/list",
      params = { cursor = "garbage" } })
    assert.equal(-32602, r[1].error.code)
  end)

  it("calls a tool: table result becomes JSON text content", function()
    local srv = demo_server()
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/call",
      params = { name = "greet", arguments = { who = "Lua" } } })
    local content = r[1].result.content
    assert.equal("text", content[1].type)
    assert.same({ text = "hello Lua" }, json.decode(content[1].text))
  end)

  it("calls a tool: string result used as-is", function()
    local srv = demo_server()
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/call",
      params = { name = "shout", arguments = json.object({}) } })
    assert.equal("AAH", r[1].result.content[1].text)
  end)

  it("passes pre-shaped results through", function()
    local srv = mcp.server{ name = "s", version = "0" }
    srv:tool{ name = "raw", description = "d", input = mcp.schema.obj({}, {}),
      handler = function()
        return { content = json.array({ { type = "text", text = "raw" } }) }
      end }
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/call",
      params = { name = "raw" } })
    assert.equal("raw", r[1].result.content[1].text)
  end)

  it("maps handler errors to isError results, not protocol errors", function()
    local srv = demo_server()
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/call",
      params = { name = "boom" } })
    assert.is_true(r[1].result.isError)
    assert.equal("kaboom", r[1].result.content[1].text)
  end)

  it("errors -32602 for unknown tools", function()
    local srv = demo_server()
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/call",
      params = { name = "nope" } })
    assert.equal(-32602, r[1].error.code)
  end)

  it("emits tools list_changed notification", function()
    local srv = demo_server()
    local e = srv:engine()
    H.init(e)
    srv:tools_changed()
    local out = e:take_output()
    assert.equal("notifications/tools/list_changed", json.decode(out[1]).method)
  end)

  it("rejects duplicate tool names", function()
    local srv = demo_server()
    assert.error_matches(function()
      srv:tool{ name = "greet", description = "again",
        input = mcp.schema.obj({}, {}), handler = function() end }
    end, "already registered")
  end)

  it("rejects non-canonical cursors", function()
    local srv = demo_server()
    local e = srv:engine()
    H.init(e)
    for _, bad in ipairs({ "1e10", "51.0", "051", "-1", "0" }) do
      local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/list",
        params = { cursor = bad } })
      assert.equal(-32602, r[1].error.code, "cursor should be rejected: " .. bad)
    end
  end)

  it("rejects non-string tool names", function()
    local srv = demo_server()
    assert.error(function()
      srv:tool{ name = 123, description = "d",
        input = mcp.schema.obj({}, {}), handler = function() end }
    end)
  end)
end)

describe("tool result shaping", function()
  it("encodes a nil tool return as an empty JSON object", function()
    local srv = mcp.server{ name = "d", version = "0" }
    srv:tool{ name = "void", description = "returns nothing",
      input = mcp.schema.obj({}, {}), handler = function() return nil end }
    local e = srv:engine(); H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/call",
      params = { name = "void", arguments = json.object({}) } })
    assert.equal("text", r[1].result.content[1].type)
    assert.equal("{}", r[1].result.content[1].text)
  end)
end)

describe("tool annotations and structured output", function()
  it("emits annotations and outputSchema in tools/list when provided", function()
    local srv = mcp.server{ name = "a", version = "0" }
    srv:tool{
      name = "lookup", description = "read only",
      input = mcp.schema.obj({}, {}),
      annotations = { readOnlyHint = true, title = "Lookup" },
      output_schema = mcp.schema.obj({ value = mcp.schema.str() }, { "value" }),
      handler = function() return { value = "x" } end,
    }
    local e = srv:engine(); H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/list" })
    local t = r[1].result.tools[1]
    assert.is_true(t.annotations.readOnlyHint)
    assert.equal("Lookup", t.annotations.title)
    assert.equal("object", t.outputSchema.type)
  end)

  it("omits annotations and outputSchema when not provided", function()
    local srv = mcp.server{ name = "a", version = "0" }
    srv:tool{ name = "plain", description = "p", input = mcp.schema.obj({}, {}),
      handler = function() return "ok" end }
    local e = srv:engine(); H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/list" })
    local t = r[1].result.tools[1]
    assert.is_nil(t.annotations)
    assert.is_nil(t.outputSchema)
  end)

  it("passes a handler's structuredContent through unchanged", function()
    local srv = mcp.server{ name = "a", version = "0" }
    srv:tool{ name = "s", description = "s", input = mcp.schema.obj({}, {}),
      handler = function()
        return {
          content = json.array({ { type = "text", text = "12.3" } }),
          structuredContent = { temperature = 12.3 },
        }
      end }
    local e = srv:engine(); H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/call",
      params = { name = "s", arguments = json.object({}) } })
    assert.equal(12.3, r[1].result.structuredContent.temperature)
    assert.equal("12.3", r[1].result.content[1].text)
  end)

  it("adds text content when a handler returns only structuredContent", function()
    local srv = mcp.server{ name = "a", version = "0" }
    srv:tool{ name = "s", description = "s", input = mcp.schema.obj({}, {}),
      handler = function() return { structuredContent = { temperature = 12.3 } } end }
    local e = srv:engine(); H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/call",
      params = { name = "s", arguments = json.object({}) } })
    assert.equal(12.3, r[1].result.structuredContent.temperature)
    assert.same({ temperature = 12.3 }, json.decode(r[1].result.content[1].text))
  end)

  it("returns a plain table as structuredContent when the tool declares output_schema", function()
    local srv = mcp.server{ name = "a", version = "0" }
    srv:tool{ name = "s", description = "s", input = mcp.schema.obj({}, {}),
      output_schema = mcp.schema.obj({ value = mcp.schema.str() }, { "value" }),
      handler = function() return { value = "x" } end }
    local e = srv:engine(); H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/call",
      params = { name = "s", arguments = json.object({}) } })
    assert.equal("x", r[1].result.structuredContent.value)
    assert.same({ value = "x" }, json.decode(r[1].result.content[1].text))
  end)

  it("keeps plain table results as text only without output_schema", function()
    local srv = mcp.server{ name = "a", version = "0" }
    srv:tool{ name = "s", description = "s", input = mcp.schema.obj({}, {}),
      handler = function() return { value = "x" } end }
    local e = srv:engine(); H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/call",
      params = { name = "s", arguments = json.object({}) } })
    assert.is_nil(r[1].result.structuredContent)
  end)
end)

describe("unencodable results", function()
  it("answers -32603 instead of crashing when a result cannot be encoded", function()
    local srv = mcp.server{ name = "a", version = "0" }
    srv:tool{ name = "f", description = "f", input = mcp.schema.obj({}, {}),
      handler = function() return { content = json.array({ { type = "text", text = print } }) } end }
    local e = srv:engine(); H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/call",
      params = { name = "f", arguments = json.object({}) } })
    assert.equal(2, r[1].id)
    assert.equal(-32603, r[1].error.code)
    local after = H.rpc(e, { jsonrpc = "2.0", id = 3, method = "ping" })
    assert.equal(3, after[1].id)
  end)

  it("drops an unencodable notification without breaking the session", function()
    local srv = mcp.server{ name = "a", version = "0" }
    local e = srv:engine(); H.init(e)
    e:notify("notifications/message", { data = print })
    assert.same({}, e:take_output())
    local after = H.rpc(e, { jsonrpc = "2.0", id = 3, method = "ping" })
    assert.equal(3, after[1].id)
  end)
end)
