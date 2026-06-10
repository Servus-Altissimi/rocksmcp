-- Facade over the active JSON codec. Codec interface:
--   name, encode(v)->str, decode(str)->v|nil,err, null (sentinel),
--   array(t)->t tagged as JSON array, object(t)->t tagged as JSON object
local M = {}

local active

local function codec()
  if not active then
    active = require("rocksmcp.json.dkjson")
  end
  return active
end

-- Swap codec (table, or module name like "rocksmcp.json.cjson").
-- Returns the previous codec so callers can restore it.
-- NOTE: null sentinels are codec-specific. Values decoded under one codec
-- must not be re-encoded under another — the old sentinel would encode as
-- an ordinary value.
function M.use(c)
  if type(c) == "string" then c = require(c) end
  assert(type(c) == "table" and c.encode and c.decode and c.null ~= nil
    and c.array and c.object, "invalid JSON codec")
  local prev = codec()
  active = c
  return prev
end

function M.encode(v) return codec().encode(v) end
function M.decode(s) return codec().decode(s) end
function M.null() return codec().null end
function M.array(t) return codec().array(t) end
function M.object(t) return codec().object(t) end

return M
