-- Best-effort lua-cjson adapter. Empty-array fidelity requires cjson's
-- array metatable (cjson.array_mt / empty_array_mt, present in 2.1.0.10+
-- and OpenResty's fork); without it, empty tables encode as {}.
local ok, cjson = pcall(require, "cjson.safe")
if not ok then cjson = require("cjson") end

local M = { name = "cjson", null = cjson.null }

local array_mt = cjson.array_mt or cjson.empty_array_mt

function M.encode(value)
  return cjson.encode(value)
end

function M.decode(str)
  local v, err = cjson.decode(str)
  if v == nil then return nil, err end
  return v
end

function M.array(t)
  t = t or {}
  if array_mt then return setmetatable(t, array_mt) end
  return t
end

function M.object(t)
  return t or {}
end

return M
