local json = require("rocksmcp.json")
local H = require("spec.helper")

describe("integration", function()
  it("echo example builds a working server", function()
    local srv = dofile("examples/echo.lua")
    local e = srv:engine()
    local init = H.init(e)
    assert.equal("echo", init.serverInfo.name)
    assert.is_true(init.capabilities.tools.listChanged)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/call",
      params = { name = "echo", arguments = { text = "bounce" } } })
    assert.equal("bounce", r[1].result.content[1].text)
  end)

  it("fileserver example serves resources", function()
    local srv = dofile("examples/fileserver.lua")
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "resources/read",
      params = { uri = "example://greeting" } })
    assert.matches("Hello", r[1].result.contents[1].text)
  end)
end)
