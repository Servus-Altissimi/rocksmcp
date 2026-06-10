local json = require("rocksmcp.json")

local S = {}

local function prim(jtype)
  return function(desc, opts)
    opts = opts or {}
    return {
      type = jtype,
      description = desc,
      minimum = opts.min,
      maximum = opts.max,
      default = opts.default,
      pattern = opts.pattern,
    }
  end
end

S.str = prim("string")
S.num = prim("number")
S.int = prim("integer")
S.bool = prim("boolean")

function S.obj(properties, required, desc)
  local sch = {
    type = "object",
    properties = json.object(properties or {}),
    description = desc,
  }
  if required and #required > 0 then
    sch.required = json.array(required)
  end
  return sch
end

function S.arr(items, desc)
  return { type = "array", items = items, description = desc }
end

function S.enum(values, desc)
  return { type = "string", enum = json.array(values), description = desc }
end

return S
