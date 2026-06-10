#!/usr/bin/env lua
-- Smoke test: exercises the coroutine park/resume path (5.1-sensitive)
-- Usage: lua scripts/smoke.lua
package.path = "./src/?.lua;./src/?/init.lua;./.rocks/share/lua/5.4/?.lua;"
  .. "./.rocks/share/lua/5.4/?/init.lua;" .. package.path

local mcp = require("rocksmcp")
local json = require("rocksmcp.json")

local srv = mcp.server{ name = "smoke", version = "0" }
srv:tool{
  name = "ask", description = "Uses sampling",
  input = mcp.schema.obj({}, {}),
  handler = function(args, ctx)
    local res = ctx.sample({ maxTokens = 1 })
    return "client said: " .. res.text
  end,
}

local e = srv:engine()

local function feed(msg)
  local outs = e:feed(json.encode(msg))
  local dec = {}
  for i, l in ipairs(outs) do dec[i] = json.decode(l) end
  return dec
end

local init = feed({ jsonrpc = "2.0", id = 1, method = "initialize",
  params = { protocolVersion = "2025-06-18",
             capabilities = { sampling = json.object({}) },
             clientInfo = { name = "smoke", version = "0" } } })
assert(init[1].result.serverInfo.name == "smoke", "initialize failed")

feed({ jsonrpc = "2.0", method = "notifications/initialized" })

-- exercise the coroutine park/resume path (yield-across-resume, 5.1-sensitive)
local outs = feed({ jsonrpc = "2.0", id = 2, method = "tools/call",
  params = { name = "ask", arguments = json.object({}) } })
assert(outs[1].method == "sampling/createMessage", "expected sampling request")

local fin = feed({ jsonrpc = "2.0", id = outs[1].id, result = { text = "ok" } })
assert(fin[1].result.content[1].text == "client said: ok", "resume failed")

print(_VERSION .. (jit and (" (" .. jit.version .. ")") or "") .. ": smoke OK")
