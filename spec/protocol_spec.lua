local protocol = require("rocksmcp.protocol")
local json = require("rocksmcp.json")
local H = require("spec.helper")

local function new_session(opts)
  opts = opts or {}
  return protocol.new({
    info = { name = "t", version = "0" },
    instructions = opts.instructions,
    capabilities = opts.capabilities or function() return json.object({}) end,
    methods = opts.methods or {},
  })
end

describe("protocol lifecycle", function()
  it("negotiates a supported protocol version", function()
    local res = H.init(new_session(), "2025-03-26")
    assert.equal("2025-03-26", res.protocolVersion)
    assert.equal("t", res.serverInfo.name)
  end)

  it("falls back to its own version for unknown client versions", function()
    local res = H.init(new_session(), "2099-01-01")
    assert.equal("2025-06-18", res.protocolVersion)
  end)

  it("includes instructions when set", function()
    local res = H.init(new_session({ instructions = "be nice" }))
    assert.equal("be nice", res.instructions)
  end)

  it("rejects double initialize", function()
    local s = new_session()
    H.init(s)
    local r = H.rpc(s, { jsonrpc = "2.0", id = 9, method = "initialize",
      params = { protocolVersion = "2025-06-18" } })
    assert.equal(-32600, r[1].error.code)
  end)

  it("rejects requests before initialize except ping", function()
    local s = new_session()
    local pong = H.rpc(s, { jsonrpc = "2.0", id = 1, method = "ping" })
    assert.is_table(pong[1].result)
    local r = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "tools/list" })
    assert.equal(-32002, r[1].error.code)
  end)

  it("answers ping after init", function()
    local s = new_session()
    H.init(s)
    local r = H.rpc(s, { jsonrpc = "2.0", id = 5, method = "ping" })
    assert.is_table(r[1].result)
  end)

  it("ignores notifications and unknown notifications", function()
    local s = new_session()
    H.init(s)
    assert.same({}, s:feed(json.encode({ jsonrpc = "2.0", method = "notifications/whatever" })))
  end)

  it("errors on parse failure with null id", function()
    local s = new_session()
    local r = json.decode(s:feed("{nope")[1])
    assert.equal(-32700, r.error.code)
  end)

  it("rejects batches", function()
    local s = new_session()
    local r = json.decode(s:feed('[{"jsonrpc":"2.0","id":1,"method":"ping"}]')[1])
    assert.equal(-32600, r.error.code)
  end)

  it("errors on unknown method", function()
    local s = new_session()
    H.init(s)
    local r = H.rpc(s, { jsonrpc = "2.0", id = 3, method = "bogus" })
    assert.equal(-32601, r[1].error.code)
  end)

  it("sets log level via logging/setLevel", function()
    local s = new_session()
    H.init(s)
    local r = H.rpc(s, { jsonrpc = "2.0", id = 4, method = "logging/setLevel",
      params = { level = "warning" } })
    assert.is_table(r[1].result)
    assert.equal("warning", s.log_level)
    local bad = H.rpc(s, { jsonrpc = "2.0", id = 5, method = "logging/setLevel",
      params = { level = "loud" } })
    assert.equal(-32602, bad[1].error.code)
  end)

  it("exposes client info after init", function()
    local s = new_session()
    H.init(s)
    assert.equal("test", s.client.info.name)
  end)

  it("queues server notifications for the transport", function()
    local s = new_session()
    H.init(s)
    s:notify("notifications/tools/list_changed", nil)
    local out = s:take_output()
    assert.equal(1, #out)
    assert.equal("notifications/tools/list_changed", json.decode(out[1]).method)
  end)

  it("returns empty object result for nil handler results", function()
    local s = protocol.new({
      info = { name = "t", version = "0" },
      capabilities = function() return json.object({}) end,
      methods = { ["x/nilret"] = { run = function() return nil end } },
    })
    H.init(s)
    local r = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "x/nilret" })
    assert.is_table(r[1].result)
    assert.is_nil(r[1].error)
  end)

  it("rejects duplicate in-flight request ids", function()
    local s = protocol.new({
      info = { name = "t", version = "0" },
      capabilities = function() return json.object({}) end,
      methods = { ["x/park"] = { run = function(p, ctx)
        return ctx.sample({})
      end } },
    })
    H.rpc(s, { jsonrpc = "2.0", id = 1, method = "initialize",
      params = { protocolVersion = "2025-06-18",
                 capabilities = { sampling = json.object({}) },
                 clientInfo = { name = "c", version = "0" } } })
    H.rpc(s, { jsonrpc = "2.0", id = 7, method = "x/park" })
    local dup = H.rpc(s, { jsonrpc = "2.0", id = 7, method = "x/park" })
    assert.equal(-32600, dup[1].error.code)
  end)

  it("rejects valid non-object json as invalid request", function()
    local s = protocol.new({
      info = { name = "t", version = "0" },
      capabilities = function() return json.object({}) end,
      methods = {},
    })
    local r = json.decode(s:feed("42")[1])
    assert.equal(-32600, r.error.code)
  end)

  it("fails handlers that yield outside client requests", function()
    local s = protocol.new({
      info = { name = "t", version = "0" },
      capabilities = function() return json.object({}) end,
      methods = { ["x/stray"] = { run = function() coroutine.yield() return 1 end } },
    })
    H.init(s)
    local r = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "x/stray" })
    assert.equal(-32603, r[1].error.code)
    assert.matches("yielded outside", r[1].error.message)
  end)

  it("rejects null request ids", function()
    local s = new_session()
    local r = H.rpc(s, { jsonrpc = "2.0", id = json.null(), method = "ping" })
    assert.equal(-32600, r[1].error.code)
  end)

  it("cancelling a parked request cancels the outgoing client request", function()
    local s = protocol.new({
      info = { name = "t", version = "0" },
      capabilities = function() return json.object({}) end,
      methods = { ["x/park"] = { run = function(p, ctx) return ctx.sample({}) end } },
    })
    H.rpc(s, { jsonrpc = "2.0", id = 1, method = "initialize",
      params = { protocolVersion = "2025-06-18",
                 capabilities = { sampling = json.object({}) },
                 clientInfo = { name = "c", version = "0" } } })
    local outs = H.rpc(s, { jsonrpc = "2.0", id = 7, method = "x/park" })
    local out_id = outs[1].id
    local notes = H.rpc(s, { jsonrpc = "2.0", method = "notifications/cancelled",
      params = { requestId = 7 } })
    assert.equal("notifications/cancelled", notes[1].method)
    assert.equal(out_id, notes[1].params.requestId)
    -- a late response for the abandoned request is silently dropped
    assert.same({}, s:feed(json.encode({ jsonrpc = "2.0", id = out_id, result = {} })))
  end)
end)
