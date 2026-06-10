local dkjson = require("dkjson")

local M = { name = "dkjson", null = dkjson.null }

function M.encode(value)
  return dkjson.encode(value)
end

function M.decode(str)
  local v, _, err = dkjson.decode(str, 1, dkjson.null)
  if err then return nil, err end
  return v
end

function M.array(t)
  return setmetatable(t or {}, { __jsontype = "array" })
end

function M.object(t)
  return setmetatable(t or {}, { __jsontype = "object" })
end

return M
