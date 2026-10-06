-- JSON Schema builders for tool inputs and outputs, plus a validator for the
-- subset they emit. Every builder returns a fresh table; nothing is shared.
local json = require("rocksmcp.json")

---@class rocksmcp.Schema: table
---@field type? string
---@field description? string

---@class rocksmcp.ScalarOpts
---@field min? number            minimum (numbers)
---@field max? number            maximum (numbers)
---@field min_length? integer    minLength in characters (strings)
---@field max_length? integer    maxLength in characters (strings)
---@field default? any
---@field pattern? string        emitted for clients; not checked by validate()

---@class rocksmcp.ArrayOpts
---@field min_items? integer
---@field max_items? integer

---@class rocksmcp.ObjectOpts
---@field additional? boolean|rocksmcp.Schema  false rejects unknown keys; a schema types them

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
  ---@param desc? string
  ---@param opts? rocksmcp.ScalarOpts
  ---@return rocksmcp.Schema
  return function(desc, opts)
    opts = opts or {}
    return {
      type = jtype,
      description = desc,
      minimum = opts.min,
      maximum = opts.max,
      minLength = opts.min_length,
      maxLength = opts.max_length,
      default = opts.default,
      pattern = opts.pattern,
    }
  end
end

S.str = prim("string")
S.num = prim("number")
S.int = prim("integer")
S.bool = prim("boolean")

--- An object. `required` lists property names the caller must send.
---@param properties? table<string, rocksmcp.Schema>
---@param required? string[]
---@param desc? string
---@param opts? rocksmcp.ObjectOpts
---@return rocksmcp.Schema
function S.obj(properties, required, desc, opts)
  local sch = {
    type = "object",
    properties = json.object(copy_map(properties or {})),
    description = desc,
  }
  if required and #required > 0 then
    sch.required = json.array(copy_list(required))
  end
  if opts and opts.additional ~= nil then
    sch.additionalProperties = opts.additional
  end
  return sch
end

---@param items rocksmcp.Schema
---@param desc? string
---@param opts? rocksmcp.ArrayOpts
---@return rocksmcp.Schema
function S.arr(items, desc, opts)
  opts = opts or {}
  return { type = "array", items = items, description = desc,
    minItems = opts.min_items, maxItems = opts.max_items }
end

---@param values string[]
---@param desc? string
---@return rocksmcp.Schema
function S.enum(values, desc)
  return { type = "string", enum = json.array(copy_list(values)), description = desc }
end

--- An object with free keys whose values all match `values` (a map).
---@param values rocksmcp.Schema
---@param desc? string
---@return rocksmcp.Schema
function S.map(values, desc)
  return { type = "object", additionalProperties = values, description = desc }
end

--- Any JSON value: no type constraint at all.
---@param desc? string
---@return rocksmcp.Schema
function S.any(desc)
  return { description = desc }
end

--- `schema`, or JSON null.
---@param schema rocksmcp.Schema
---@return rocksmcp.Schema
function S.nullable(schema)
  local out = copy_map(schema)
  if type(out.type) == "string" then
    out.type = json.array({ out.type, "null" })
  end
  return out
end

-- validation ----------------------------------------------------------------

local function is_array(v)
  if type(v) ~= "table" then return false end
  local mt = getmetatable(v)
  if mt and mt.__jsontype == "object" then return false end
  if mt and mt.__jsontype == "array" then return true end
  local n = 0
  for _ in pairs(v) do n = n + 1 end
  return n == #v and (n > 0 or (mt and mt.__jsontype == "array") or false)
end

local function chars(s)
  local _, cont = s:gsub("[\128-\191]", "")
  return #s - cont
end

local function json_type(v)
  if v == json.null() then return "null" end
  local t = type(v)
  if t == "string" then return "string" end
  if t == "boolean" then return "boolean" end
  if t == "number" then return (v == math.floor(v) and v > -math.huge and v < math.huge) and "integer" or "number" end
  if t == "table" then
    if next(v) == nil then
      local mt = getmetatable(v)
      return mt and mt.__jsontype == "array" and "array" or "object"
    end
    return is_array(v) and "array" or "object"
  end
  return t
end

local function type_ok(want, got)
  return want == got or (want == "number" and got == "integer")
end

local function empty_table(v)
  return type(v) == "table" and next(v) == nil
end

local function check(schema, v, path, errs)
  if type(schema) ~= "table" then return end
  local want = schema.type
  if want ~= nil then
    local got = json_type(v)
    local wants = type(want) == "table" and want or { want }
    local ok = false
    for _, w in ipairs(wants) do
      -- an empty table decodes the same for [] and {}, so it passes as either
      if type_ok(w, got) or ((w == "array" or w == "object") and empty_table(v)) then ok = true end
    end
    if not ok then
      local names = {}
      for i, w in ipairs(wants) do names[i] = w end
      errs[#errs + 1] = ("%s must be %s, got %s"):format(path, table.concat(names, " or "), got)
      return
    end
  end
  if schema.enum and type(schema.enum) == "table" then
    local found = false
    for _, e in ipairs(schema.enum) do if e == v then found = true end end
    if not found then
      local names = {}
      for i, e in ipairs(schema.enum) do names[i] = tostring(e) end
      errs[#errs + 1] = ("%s must be one of: %s"):format(path, table.concat(names, ", "))
      return
    end
  end
  local t = type(v)
  if t == "number" then
    if schema.minimum and v < schema.minimum then errs[#errs + 1] = ("%s must be >= %s"):format(path, schema.minimum) end
    if schema.maximum and v > schema.maximum then errs[#errs + 1] = ("%s must be <= %s"):format(path, schema.maximum) end
  elseif t == "string" then
    local n = chars(v)
    if schema.minLength and n < schema.minLength then
      errs[#errs + 1] = ("%s must be at least %d characters"):format(path, schema.minLength)
    end
    if schema.maxLength and n > schema.maxLength then
      errs[#errs + 1] = ("%s must be at most %d characters (got %d)"):format(path, schema.maxLength, n)
    end
  elseif t == "table" then
    local as_array = is_array(v)
    if empty_table(v) then
      -- {} and [] look alike once decoded; read it as the schema expects
      as_array = schema.type == "array"
    end
    if as_array then
      if schema.minItems and #v < schema.minItems then
        errs[#errs + 1] = ("%s must have at least %d items"):format(path, schema.minItems)
      end
      if schema.maxItems and #v > schema.maxItems then
        errs[#errs + 1] = ("%s must have at most %d items"):format(path, schema.maxItems)
      end
      if schema.items then
        for i, x in ipairs(v) do check(schema.items, x, ("%s[%d]"):format(path, i - 1), errs) end
      end
    else
      local props = schema.properties or {}
      for _, name in ipairs(schema.required or {}) do
        if v[name] == nil or v[name] == json.null() then
          errs[#errs + 1] = ("%s.%s is required"):format(path, name)
        end
      end
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      for _, k in ipairs(keys) do
        local sub = props[k]
        local x = v[k]
        if sub ~= nil then
          -- null on an optional field means absent; a required one was reported above
          if x ~= json.null() then check(sub, x, path .. "." .. k, errs) end
        elseif schema.additionalProperties == false then
          local known = {}
          for name in pairs(props) do known[#known + 1] = name end
          table.sort(known)
          errs[#errs + 1] = ("%s.%s is not a known field (known: %s)"):format(path, k, table.concat(known, ", "))
        elseif type(schema.additionalProperties) == "table" then
          check(schema.additionalProperties, x, path .. "." .. k, errs)
        end
      end
    end
  end
end

--- Check `value` against `schema`. Returns true, or false and a list of
--- readable problems ("arguments.limit must be integer, got string").
--- Checks type, enum, required, min/max, lengths, item counts, items,
--- properties and additionalProperties; not pattern, oneOf or $ref.
---@param schema rocksmcp.Schema
---@param value any
---@param root? string  name for the top level in messages (default "arguments")
---@return boolean ok
---@return string[]? problems
function S.validate(schema, value, root)
  local errs = {}
  check(schema, value, root or "arguments", errs)
  if #errs == 0 then return true end
  return false, errs
end

return S
