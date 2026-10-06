local mcp = require("rocksmcp")
local S = mcp.schema

local function srv() return mcp.server{ name = "t", version = "0" } end

local function err_of(fn)
  local ok, e = pcall(fn)
  assert.is_false(ok)
  return e
end

describe("registration", function()
  local said, prev
  before_each(function()
    said = {}
    prev = mcp.set_diagnostics(function(m) said[#said + 1] = m end)
  end)
  after_each(function() mcp.set_diagnostics(prev) end)

  it("names a typo and what was meant", function()
    local e = err_of(function()
      srv():tool{ name = "x", description = "d", inputSchema = S.obj({}), fn = function() end }
    end)
    assert.matches("unknown field 'inputSchema' %(did you mean 'input'%?%)", e)
    assert.matches("unknown field 'fn' %(did you mean 'handler'%?%)", e)
    assert.matches("handler must be a function", e)
  end)

  it("lists allowed fields for an unknown key with no hint", function()
    local e = err_of(function()
      srv():tool{ name = "x", description = "d", handler = function() end, colour = "red" }
    end)
    assert.matches("unknown field 'colour' %(allowed: .*handler", e)
  end)

  it("points the error at the caller's line", function()
    local e = err_of(function() srv():tool{ name = "x", handler = 1 } end)
    assert.matches("registration_spec%.lua:%d+:", e)
  end)

  it("rejects a non-object input schema", function()
    local e = err_of(function()
      srv():tool{ name = "x", description = "d", input = S.str(), handler = function() end }
    end)
    assert.matches("input must be an object schema", e)
  end)

  it("rejects bad names and duplicates", function()
    assert.matches("letters, digits", err_of(function()
      srv():tool{ name = "has space", description = "d", handler = function() end }
    end))
    local s = srv()
    s:tool{ name = "x", description = "d", handler = function() end }
    assert.matches("already registered", err_of(function()
      s:tool{ name = "x", description = "d", handler = function() end }
    end))
  end)

  it("defaults input to an empty object schema", function()
    local s = srv()
    s:tool{ name = "x", description = "d", handler = function() end }
    assert.equal("object", s.registry.tools.x.input.type)
  end)

  it("warns on a missing description without failing", function()
    srv():tool{ name = "x", handler = function() end }
    assert.equal(1, #said)
    assert.matches("'x' has no description", said[1])
  end)

  it("checks server options", function()
    local e = err_of(function() mcp.server{ name = "", version = "0", validate = true } end)
    assert.matches("name must be a non%-empty string", e)
    assert.matches("unknown field 'validate'", e)
    assert.matches("max_result_bytes", err_of(function()
      mcp.server{ name = "x", version = "0", max_result_bytes = 0 }
    end))
  end)
end)
