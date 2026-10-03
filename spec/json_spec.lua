local json = require("rocksmcp.json")

describe("json facade", function()
  it("defaults to dkjson and round-trips", function()
    local s = json.encode({ a = 1, b = json.array({ 1, 2 }) })
    local t = json.decode(s)
    assert.equal(1, t.a)
    assert.equal(2, t.b[2])
  end)

  it("encodes tagged empty containers distinctly", function()
    assert.equal("[]", json.encode(json.array({})))
    assert.equal("{}", json.encode(json.object({})))
  end)

  it("decodes null to a stable sentinel", function()
    local t = json.decode('{"x":null,"l":[1,null]}')
    assert.equal(json.null(), t.x)
    assert.equal(json.null(), t.l[2])
    assert.equal(2, #t.l)
  end)

  it("encodes the sentinel back to null", function()
    assert.equal("[null]", json.encode(json.array({ json.null() })))
  end)

  it("returns nil on invalid input", function()
    assert.is_nil(json.decode("{nope"))
  end)

  it("can swap codecs and restore", function()
    local fake = {
      name = "fake",
      encode = function() return "FAKE" end,
      decode = function() return { fake = true } end,
      null = {},
      array = function(t) return t end,
      object = function(t) return t end,
    }
    local prev = json.use(fake)
    assert.equal("FAKE", json.encode({}))
    json.use(prev)
    assert.equal("[]", json.encode(json.array({})))
  end)
end)

describe("cjson adapter", function()
  local ok = pcall(require, "cjson")
  if not ok then
    pending("lua-cjson not installed; adapter untested here", function() end)
    return
  end
  it("round-trips with null sentinel", function()
    local cj = require("rocksmcp.json.cjson")
    local t = cj.decode('{"x":null}')
    assert.equal(cj.null, t.x)
    assert.is_string(cj.encode({ a = 1 }))
  end)
end)

describe("cjson adapter details", function()
  local ok = pcall(require, "cjson")
  if not ok then
    pending("lua-cjson not installed", function() end)
    return
  end
  it("tags empty arrays, builds objects, and reports decode errors", function()
    local cj = require("rocksmcp.json.cjson")
    assert.equal("[]", cj.encode(cj.array({})))
    assert.is_table(cj.object({}))
    assert.is_nil(cj.decode("{bad"))
  end)
end)
