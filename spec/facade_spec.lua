local mcp = require("rocksmcp")
local json = require("rocksmcp.json")
local H = require("spec.helper")

describe("mcp facade", function()
  it("use_json swaps the active codec and returns the previous one", function()
    local prev = mcp.use_json("rocksmcp.json.cjson")
    finally(function() mcp.use_json(prev) end)
    assert.equal("dkjson", prev.name)
    local cj = require("rocksmcp.json.cjson")
    assert.equal(cj.null, json.null())
  end)

  it("assistant_text builds an assistant-role text message", function()
    local m = mcp.assistant_text("hi")
    assert.equal("assistant", m.role)
    assert.equal("text", m.content.type)
    assert.equal("hi", m.content.text)
  end)

  it("resources_changed queues a resources list_changed notification", function()
    local srv = mcp.server{ name = "x", version = "0" }
    srv:resource{ uri = "x://a", name = "A", read = function() return "a" end }
    local e = srv:engine()
    H.init(e)
    e:take_output()
    srv:resources_changed()
    local out = e:take_output()
    assert.equal(1, #out)
    assert.equal("notifications/resources/list_changed", json.decode(out[1]).method)
  end)

  it("prompts_changed queues a prompts list_changed notification", function()
    local srv = mcp.server{ name = "x", version = "0" }
    srv:prompt{ name = "p", get = function() return { messages = json.array({}) } end }
    local e = srv:engine()
    H.init(e)
    e:take_output()
    srv:prompts_changed()
    local out = e:take_output()
    assert.equal(1, #out)
    assert.equal("notifications/prompts/list_changed", json.decode(out[1]).method)
  end)

  it("run serves framed JSON-RPC over stdio", function()
    local srv = mcp.server{ name = "echo", version = "0" }
    srv:tool{ name = "ping", description = "ping", input = mcp.schema.obj({}, {}),
      handler = function() return "pong" end }

    local input = table.concat({
      json.encode({ jsonrpc = "2.0", id = 1, method = "initialize", params = {
        protocolVersion = "2025-06-18", capabilities = json.object({}),
        clientInfo = { name = "c", version = "0" } } }),
      json.encode({ jsonrpc = "2.0", method = "notifications/initialized" }),
      json.encode({ jsonrpc = "2.0", id = 2, method = "tools/call",
        params = { name = "ping", arguments = json.object({}) } }),
    }, "\n") .. "\n"

    local infile = io.tmpfile(); infile:write(input); infile:seek("set")
    local outfile = io.tmpfile()
    local old_in, old_out = io.stdin, io.stdout
    io.stdin, io.stdout = infile, outfile
    finally(function()
      io.stdin, io.stdout = old_in, old_out
      infile:close(); outfile:close()
    end)

    srv:run()

    io.stdin, io.stdout = old_in, old_out
    outfile:seek("set")
    local content = outfile:read("*a")
    assert.truthy(content:find("pong", 1, true))
    assert.truthy(content:find('"id":2', 1, true))
  end)
end)
