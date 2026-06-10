local mcp = require("rocksmcp")
local json = require("rocksmcp.json")
local H = require("spec.helper")

local function prompt_server()
  local srv = mcp.server{ name = "p", version = "0" }
  srv:prompt{
    name = "review", description = "Code review",
    args = {
      { name = "lang", description = "Language", required = true },
      { name = "style", required = false },
    },
    get = function(args)
      return { messages = json.array({ mcp.user_text("Review some " .. args.lang) }) }
    end,
  }
  srv:completion(function(ref, argument)
    if argument and argument.name == "lang" then
      return { "lua", "luajit" }
    end
    return {}
  end)
  return srv
end

describe("prompts", function()
  it("advertises prompts and completions capabilities", function()
    local res = H.init(prompt_server():engine())
    assert.is_true(res.capabilities.prompts.listChanged)
    assert.is_table(res.capabilities.completions)
  end)

  it("lists prompts with argument descriptors", function()
    local e = prompt_server():engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "prompts/list" })
    local p = r[1].result.prompts[1]
    assert.equal("review", p.name)
    assert.equal("lang", p.arguments[1].name)
    assert.is_true(p.arguments[1].required)
  end)

  it("gets a prompt", function()
    local e = prompt_server():engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "prompts/get",
      params = { name = "review", arguments = { lang = "lua" } } })
    local m = r[1].result.messages[1]
    assert.equal("user", m.role)
    assert.equal("Review some lua", m.content.text)
  end)

  it("rejects missing required arguments", function()
    local e = prompt_server():engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "prompts/get",
      params = { name = "review", arguments = json.object({}) } })
    assert.equal(-32602, r[1].error.code)
    assert.matches("lang", r[1].error.message)
  end)

  it("errors on unknown prompt", function()
    local e = prompt_server():engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "prompts/get",
      params = { name = "nope" } })
    assert.equal(-32602, r[1].error.code)
  end)

  it("completes argument values", function()
    local e = prompt_server():engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "completion/complete",
      params = { ref = { type = "ref/prompt", name = "review" },
                 argument = { name = "lang", value = "l" } } })
    assert.same({ "lua", "luajit" }, r[1].result.completion.values)
  end)

  it("caps completion values at 100", function()
    local srv = mcp.server{ name = "s", version = "0" }
    srv:prompt{ name = "p", get = function() return { messages = json.array({}) } end }
    srv:completion(function()
      local v = {}
      for i = 1, 150 do v[i] = "v" .. i end
      return v
    end)
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "completion/complete",
      params = { ref = { type = "ref/prompt", name = "p" },
                 argument = { name = "x", value = "" } } })
    assert.equal(100, #r[1].result.completion.values)
  end)

  it("errors when no completion handler is registered", function()
    local srv = mcp.server{ name = "s", version = "0" }
    srv:prompt{ name = "p", get = function() return { messages = json.array({}) } end }
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "completion/complete",
      params = { ref = { type = "ref/prompt", name = "p" },
                 argument = { name = "x", value = "" } } })
    assert.equal(-32601, r[1].error.code)
  end)
end)
