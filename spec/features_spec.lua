local mcp = require("rocksmcp")
local testing = require("rocksmcp.testing")
local S = mcp.schema

describe("mcp.result", function()
  local function client(handler)
    local srv = mcp.server{ name = "t", version = "0" }
    srv:tool{ name = "x", description = "d", handler = handler }
    return testing.client(srv)
  end

  it("sends a marked result as-is", function()
    local r = client(function()
      return mcp.result{ content = { mcp.text("a"), mcp.text("b") }, isError = true }
    end):call("x")
    assert.is_true(r.isError)
    assert.equal(2, #r.content)
    assert.equal("a\nb", r.text)
  end)

  it("fills text content for structuredContent only", function()
    local r = client(function() return mcp.result{ structuredContent = { count = 1 } } end):call("x")
    assert.equal(1, r.structuredContent.count)
    assert.equal(1, r.data.count)
  end)

  it("treats data with a content field as data", function()
    local r = client(function() return { content = "page body", title = "t" } end):call("x")
    assert.equal("page body", r.data.content)
    assert.equal("t", r.data.title)
  end)

  it("still passes an unmarked list of content blocks", function()
    local r = client(function() return { content = { mcp.text("raw") } } end):call("x")
    assert.equal("raw", r.text)
  end)
end)

describe("validate_input", function()
  local function server(opts, tool_validate)
    local srv = mcp.server{ name = "t", version = "0", validate_input = opts }
    local ran = 0
    srv:tool{
      name = "x", description = "d", validate = tool_validate,
      input = S.obj({ n = S.int("N", { min = 1 }), tags = S.arr(S.str()) }, { "n" }, nil, { additional = false }),
      handler = function() ran = ran + 1; return "ok" end,
    }
    return testing.client(srv), function() return ran end
  end

  it("refuses bad arguments with every problem, without running the handler", function()
    local c, ran = server(true)
    local r = c:call("x", { n = 0, tags = { 1 }, extra = true })
    assert.is_true(r.isError)
    assert.matches("arguments%.n must be >= 1", r.text)
    assert.matches("arguments%.tags%[0%] must be string, got integer", r.text)
    assert.matches("arguments%.extra is not a known field %(known: n, tags%)", r.text)
    assert.equal(0, ran())
  end)

  it("reports a missing required field", function()
    local r = server(true):call("x", {})
    assert.matches("arguments%.n is required", r.text)
  end)

  it("is off by default and per-tool overridable", function()
    local c, ran = server(nil)
    assert.equal("ok", c:call("x", {}).text)
    assert.equal(1, ran())
    assert.is_true(server(nil, true):call("x", {}).isError)
    assert.equal("ok", server(true, false):call("x", {}).text)
  end)
end)

describe("actions", function()
  local function client()
    local srv = mcp.server{ name = "t", version = "0", validate_input = true }
    srv:tool{
      name = "notes", description = "Notes",
      input = S.obj({ id = S.str("Id") }),
      action_order = { "list", "get" },
      actions = {
        list = function() return { "a", "b" } end,
        get = function(args) return "note " .. tostring(args.id) end,
      },
    }
    return testing.client(srv)
  end

  it("builds the action enum and requires it", function()
    local t = client():tool("notes")
    assert.same({ "list", "get" }, t.inputSchema.properties.action.enum)
    assert.same({ "action" }, t.inputSchema.required)
    assert.equal("string", t.inputSchema.properties.id.type)
  end)

  it("dispatches on action", function()
    local c = client()
    assert.same({ "a", "b" }, c:call("notes", { action = "list" }).data)
    assert.equal("note 7", c:call("notes", { action = "get", id = "7" }).text)
  end)

  it("names the actions on a bad one", function()
    local r = client():call("notes", { action = "nuke" })
    assert.is_true(r.isError)
    assert.matches("one of: list, get", r.text)
  end)

  it("rejects handler plus actions and a bad action_order", function()
    local srv = mcp.server{ name = "t", version = "0" }
    local ok, e = pcall(srv.tool, srv, { name = "x", description = "d",
      handler = function() end, actions = { a = function() end } })
    assert.is_false(ok)
    assert.matches("handler or actions, not both", e)
    ok, e = pcall(srv.tool, srv, { name = "y", description = "d",
      actions = { a = function() end }, action_order = { "a", "b" } })
    assert.is_false(ok)
    assert.matches("'b', which has no function", e)
  end)
end)

describe("max_result_bytes", function()
  it("refuses an oversized result and says how to narrow it", function()
    local srv = mcp.server{ name = "t", version = "0", max_result_bytes = 100 }
    srv:tool{ name = "big", description = "d", handler = function() return string.rep("x", 500) end }
    srv:tool{ name = "small", description = "d", handler = function() return "ok" end }
    local c = testing.client(srv)
    local r = c:call("big")
    assert.is_true(r.isError)
    assert.matches("500 bytes, over this server's limit of 100", r.text)
    assert.matches("smaller limit", r.text)
    assert.equal("ok", c:call("small").text)
  end)
end)

describe("diagnostics", function()
  local said, prev
  before_each(function()
    said = {}
    prev = mcp.set_diagnostics(function(m) said[#said + 1] = m end)
  end)
  after_each(function() mcp.set_diagnostics(prev) end)

  it("writes a traceback for a crashed handler, keeps the client message clean", function()
    local srv = mcp.server{ name = "t", version = "0" }
    srv:tool{ name = "crash", description = "d", handler = function() local t = nil; return t.x end }
    local r = testing.client(srv):call("crash")
    assert.is_true(r.isError)
    assert.not_matches("%.lua:%d+", r.text)
    assert.equal(1, #said)
    assert.matches("^tool crash failed: .*features_spec%.lua:%d+: .*stack traceback", said[1])
  end)

  it("stays quiet for deliberate errors", function()
    local srv = mcp.server{ name = "t", version = "0" }
    srv:tool{ name = "no", description = "d", handler = function() error("not found", 0) end }
    assert.equal("not found", testing.client(srv):call("no").text)
    assert.equal(0, #said)
  end)
end)

describe("testing client", function()
  it("answers server requests through on_request and collects notifications", function()
    local srv = mcp.server{ name = "t", version = "0" }
    srv:tool{ name = "ask", description = "d", handler = function(_, ctx)
      ctx.log("info", "asking")
      return "said " .. ctx.sample({ maxTokens = 1 }).text
    end }
    local c = testing.client(srv, {
      capabilities = { sampling = {} },
      on_request = function(method) return { text = method } end,
    })
    assert.equal("said sampling/createMessage", c:call("ask").text)
    assert.equal("notifications/message", c.notifications[1].method)
  end)

  it("raises on a JSON-RPC error", function()
    local c = testing.client(mcp.server{ name = "t", version = "0" })
    assert.has_error(function() c:call("nope") end)
  end)
end)
