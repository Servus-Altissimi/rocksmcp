local protocol = require("rocksmcp.protocol")
local json = require("rocksmcp.json")
local H = require("spec.helper")

local function session_with(run, on_error)
  local s = protocol.new({
    info = { name = "t", version = "0" },
    capabilities = function() return json.object({}) end,
    methods = { ["test/run"] = { run = run, on_error = on_error } },
  })
  -- client declares sampling+roots capability so gated calls pass
  H.rpc(s, {
    jsonrpc = "2.0", id = 1, method = "initialize",
    params = {
      protocolVersion = "2025-06-18",
      capabilities = { sampling = json.object({}), roots = json.object({}) },
      clientInfo = { name = "c", version = "0" },
    },
  })
  return s
end

describe("engine async", function()
  it("runs a sync handler to completion", function()
    local s = session_with(function(params) return { ok = true, got = params.x } end)
    local r = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "test/run", params = { x = 7 } })
    assert.equal(7, r[1].result.got)
  end)

  it("maps handler errors to -32603 by default", function()
    local s = session_with(function() error("boom", 0) end)
    local r = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "test/run" })
    assert.equal(-32603, r[1].error.code)
    assert.equal("boom", r[1].error.message)
  end)

  it("respects structured errors with codes", function()
    local s = session_with(function() error({ code = -32002, message = "nope" }, 0) end)
    local r = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "test/run" })
    assert.equal(-32002, r[1].error.code)
  end)

  it("strips lua location prefixes from level-1 errors", function()
    local s = session_with(function() error("plain") end)
    local r = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "test/run" })
    assert.equal("plain", r[1].error.message)
  end)

  it("parks on ctx.sample and resumes with the client response", function()
    local s = session_with(function(params, ctx)
      local res = ctx.sample({ maxTokens = 5 })
      return { answer = res.content.text }
    end)
    local outs = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "test/run" })
    -- no response yet; instead a sampling request went out
    assert.equal(1, #outs)
    assert.equal("sampling/createMessage", outs[1].method)
    local sample_id = outs[1].id
    -- feed the client's response; handler resumes and completes
    local fin = H.rpc(s, { jsonrpc = "2.0", id = sample_id,
      result = { content = { type = "text", text = "hi" } } })
    assert.equal("hi", fin[1].result.answer)
    assert.equal(2, fin[1].id)
  end)

  it("turns client error responses into handler errors", function()
    local s = session_with(function(params, ctx)
      ctx.sample({})
      return { unreachable = true }
    end)
    local outs = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "test/run" })
    local fin = H.rpc(s, { jsonrpc = "2.0", id = outs[1].id,
      error = { code = -1, message = "user said no" } })
    assert.equal(-32603, fin[1].error.code)
    assert.matches("user said no", fin[1].error.message)
  end)

  it("interleaves two in-flight requests", function()
    local s = session_with(function(params, ctx)
      local r = ctx.sample({ tag = params.tag })
      return { tag = params.tag, got = r.v }
    end)
    local o1 = H.rpc(s, { jsonrpc = "2.0", id = 10, method = "test/run", params = { tag = "a" } })
    local o2 = H.rpc(s, { jsonrpc = "2.0", id = 11, method = "test/run", params = { tag = "b" } })
    local s_a, s_b = o1[1].id, o2[1].id
    -- answer b first
    local fb = H.rpc(s, { jsonrpc = "2.0", id = s_b, result = { v = "B" } })
    assert.equal(11, fb[1].id)
    assert.equal("B", fb[1].result.got)
    local fa = H.rpc(s, { jsonrpc = "2.0", id = s_a, result = { v = "A" } })
    assert.equal(10, fa[1].id)
  end)

  it("suppresses responses for cancelled requests", function()
    local s = session_with(function(params, ctx)
      ctx.sample({})
      return { late = true }
    end)
    local outs = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "test/run" })
    H.rpc(s, { jsonrpc = "2.0", method = "notifications/cancelled",
      params = { requestId = 2 } })
    local fin = H.rpc(s, { jsonrpc = "2.0", id = outs[1].id, result = { v = 1 } })
    assert.same({}, fin) -- no response emitted
  end)

  it("marks ctx cancelled flag when cancellation arrives", function()
    local got_ctx
    local s = session_with(function(params, ctx)
      got_ctx = ctx
      ctx.sample({})
      return { late = true }
    end)
    H.rpc(s, { jsonrpc = "2.0", id = 2, method = "test/run" })
    H.rpc(s, { jsonrpc = "2.0", method = "notifications/cancelled",
      params = { requestId = 2 } })
    assert.is_true(got_ctx.cancelled())
  end)

  it("emits progress only when the request carried a token", function()
    local s = session_with(function(params, ctx)
      ctx.progress(0.5, 1, "half")
      return { ok = true }
    end)
    local with = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "test/run",
      params = { _meta = { progressToken = "tok" } } })
    assert.equal("notifications/progress", with[1].method)
    assert.equal("tok", with[1].params.progressToken)
    assert.equal(0.5, with[1].params.progress)
    assert.is_table(with[2].result)
    local without = H.rpc(s, { jsonrpc = "2.0", id = 3, method = "test/run" })
    assert.equal(1, #without)
    assert.is_table(without[1].result)
  end)

  it("filters log notifications below the set level", function()
    local s = session_with(function(params, ctx)
      ctx.log("debug", "noisy")
      ctx.log("error", "loud")
      return { ok = true }
    end)
    H.rpc(s, { jsonrpc = "2.0", id = 5, method = "logging/setLevel",
      params = { level = "warning" } })
    local outs = H.rpc(s, { jsonrpc = "2.0", id = 6, method = "test/run" })
    assert.equal(2, #outs) -- one log (error), one response
    assert.equal("notifications/message", outs[1].method)
    assert.equal("error", outs[1].params.level)
  end)

  it("rejects gated calls when the client lacks the capability", function()
    local s = protocol.new({
      info = { name = "t", version = "0" },
      capabilities = function() return json.object({}) end,
      methods = { ["test/run"] = { run = function(params, ctx) return ctx.elicit({}) end } },
    })
    H.init(s) -- helper declares NO capabilities
    local r = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "test/run" })
    assert.equal(-32603, r[1].error.code)
    assert.matches("does not support elicitation", r[1].error.message)
  end)

  it("rejects client_request from outside a handler", function()
    local s = session_with(function() return {} end)
    assert.error_matches(function()
      s:client_request("roots/list", nil)
    end, "only allowed inside")
  end)
end)

describe("engine async roots", function()
  it("parks on ctx.roots and returns the client roots", function()
    local s = session_with(function(_, ctx) return ctx.roots() end)
    local outs = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "test/run" })
    assert.equal("roots/list", outs[1].method)
    local rid = outs[1].id
    local fin = H.rpc(s, { jsonrpc = "2.0", id = rid,
      result = { roots = { { uri = "file:///x", name = "x" } } } })
    assert.equal("file:///x", fin[1].result[1].uri)
  end)
end)
