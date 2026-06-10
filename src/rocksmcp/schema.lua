local json = require("rocksmcp.json")

local S = {}

local function copy_list(t)
  local out = {}
  for i = 1, #t do out[i] = t[i] end
  return out
end

local function copy_map(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

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
    properties = json.object(copy_map(properties or {})),
    description = desc,
  }
  if required and #required > 0 then
    sch.required = json.array(copy_list(required))
  end
  return sch
end

function S.arr(items, desc)
  return { type = "array", items = items, description = desc }
end

function S.enum(values, desc)
  return { type = "string", enum = json.array(copy_list(values)), description = desc }
end

return S
