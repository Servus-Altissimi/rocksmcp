local json = require("rocksmcp.json")

local H = {}

-- feed one message table, return array of decoded out-messages
function H.rpc(session, msg)
  local outs = session:feed(json.encode(msg))
  local decoded = {}
  for i, line in ipairs(outs) do decoded[i] = json.decode(line) end
  return decoded
end

-- standard handshake; returns the initialize result
function H.init(session, protocol_version)
  local r = H.rpc(session, {
    jsonrpc = "2.0", id = 1, method = "initialize",
    params = {
      protocolVersion = protocol_version or "2025-06-18",
      capabilities = json.object({}),
      clientInfo = { name = "test", version = "0" },
    },
  })
  H.rpc(session, { jsonrpc = "2.0", method = "notifications/initialized" })
  return r[1].result
end

return H
