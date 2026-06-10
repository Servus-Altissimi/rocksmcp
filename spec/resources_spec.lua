local mcp = require("rocksmcp")
local json = require("rocksmcp.json")
local H = require("spec.helper")

local function file_server()
  local srv = mcp.server{ name = "files", version = "0" }
  srv:resource{ uri = "demo://readme", name = "README", mime = "text/plain",
    description = "The readme",
    read = function() return "hello docs" end }
  srv:resource{ uri = "demo://logo", name = "Logo", mime = "image/png",
    read = function() return { blob = "aGk=" } end }
  srv:resource_template{ uri_template = "demo://files/{path}", name = "Files",
    mime = "text/plain",
    read = function(uri, ctx, vars) return "file:" .. vars.path end }
  return srv
end

describe("resources", function()
  it("advertises resources capability with subscribe", function()
    local res = H.init(file_server():engine())
    assert.is_true(res.capabilities.resources.subscribe)
    assert.is_true(res.capabilities.resources.listChanged)
  end)

  it("lists static resources", function()
    local e = file_server():engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "resources/list" })
    local list = r[1].result.resources
    assert.equal(2, #list)
    assert.equal("demo://readme", list[1].uri)
    assert.equal("text/plain", list[1].mimeType)
    assert.equal("The readme", list[1].description)
  end)

  it("lists templates", function()
    local e = file_server():engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "resources/templates/list" })
    local list = r[1].result.resourceTemplates
    assert.equal(1, #list)
    assert.equal("demo://files/{path}", list[1].uriTemplate)
  end)

  it("reads a static text resource", function()
    local e = file_server():engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "resources/read",
      params = { uri = "demo://readme" } })
    local c = r[1].result.contents[1]
    assert.equal("demo://readme", c.uri)
    assert.equal("text/plain", c.mimeType)
    assert.equal("hello docs", c.text)
  end)

  it("reads a blob resource", function()
    local e = file_server():engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "resources/read",
      params = { uri = "demo://logo" } })
    local c = r[1].result.contents[1]
    assert.equal("aGk=", c.blob)
    assert.equal("image/png", c.mimeType)
  end)

  it("reads through a template with captured vars", function()
    local e = file_server():engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "resources/read",
      params = { uri = "demo://files/notes/today.md" } })
    assert.equal("file:notes/today.md", r[1].result.contents[1].text)
  end)

  it("errors -32002 for unknown uris", function()
    local e = file_server():engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "resources/read",
      params = { uri = "demo://missing" } })
    assert.equal(-32002, r[1].error.code)
  end)

  it("subscribes and receives updates only for subscribed uris", function()
    local srv = file_server()
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "resources/subscribe",
      params = { uri = "demo://readme" } })
    assert.is_table(r[1].result)
    srv:resource_updated("demo://readme")
    srv:resource_updated("demo://logo") -- not subscribed
    local out = e:take_output()
    assert.equal(1, #out)
    local note = json.decode(out[1])
    assert.equal("notifications/resources/updated", note.method)
    assert.equal("demo://readme", note.params.uri)
  end)

  it("unsubscribes", function()
    local srv = file_server()
    local e = srv:engine()
    H.init(e)
    H.rpc(e, { jsonrpc = "2.0", id = 2, method = "resources/subscribe",
      params = { uri = "demo://readme" } })
    H.rpc(e, { jsonrpc = "2.0", id = 3, method = "resources/unsubscribe",
      params = { uri = "demo://readme" } })
    srv:resource_updated("demo://readme")
    assert.same({}, e:take_output())
  end)

  it("escapes pattern magic in templates", function()
    local srv = mcp.server{ name = "s", version = "0" }
    srv:resource_template{ uri_template = "x+y://a.b/{n}", name = "T",
      read = function(uri, ctx, vars) return vars.n end }
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "resources/read",
      params = { uri = "x+y://a.b/42" } })
    assert.equal("42", r[1].result.contents[1].text)
    local miss = H.rpc(e, { jsonrpc = "2.0", id = 3, method = "resources/read",
      params = { uri = "xxy://aXb/42" } })
    assert.equal(-32002, miss[1].error.code)
  end)

  it("does not pollute cached handler result tables", function()
    local cached = { text = "static" }
    local srv = mcp.server{ name = "s", version = "0" }
    srv:resource{ uri = "c://one", name = "One", mime = "text/plain",
      read = function() return cached end }
    srv:resource{ uri = "c://two", name = "Two", mime = "text/x-other",
      read = function() return cached end }
    local e = srv:engine()
    H.init(e)
    H.rpc(e, { jsonrpc = "2.0", id = 2, method = "resources/read",
      params = { uri = "c://one" } })
    local r2 = H.rpc(e, { jsonrpc = "2.0", id = 3, method = "resources/read",
      params = { uri = "c://two" } })
    assert.equal("c://two", r2[1].result.contents[1].uri)
    assert.equal("text/x-other", r2[1].result.contents[1].mimeType)
    assert.is_nil(cached.uri)
  end)

  it("rejects unsubscribe without uri", function()
    local e = file_server():engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "resources/unsubscribe",
      params = json.object({}) })
    assert.equal(-32602, r[1].error.code)
  end)

  it("rejects duplicate template variables", function()
    local srv = mcp.server{ name = "s", version = "0" }
    assert.error_matches(function()
      srv:resource_template{ uri_template = "d://{x}/{x}", name = "T",
        read = function() return "" end }
    end, "duplicate variable")
  end)

  it("supports underscores in template variables", function()
    local srv = mcp.server{ name = "s", version = "0" }
    srv:resource_template{ uri_template = "d://u/{user_id}", name = "U",
      read = function(uri, ctx, vars) return "user:" .. vars.user_id end }
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "resources/read",
      params = { uri = "d://u/42" } })
    assert.equal("user:42", r[1].result.contents[1].text)
  end)
end)
