-- Minimal RocksMCP server: one tool.
-- Run directly:  lua examples/echo.lua   (from the repo root)
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local mcp = require("rocksmcp")

local srv = mcp.server{ name = "echo", version = "1.0.0",
  instructions = "Echoes text back." }

srv:tool{
  name = "echo",
  description = "Echo the input text back",
  input = mcp.schema.obj({ text = mcp.schema.str("Text to echo") }, { "text" }),
  handler = function(args)
    return args.text
  end,
}

if arg and arg[0] and arg[0]:match("echo%.lua$") then
  srv:run()
end

return srv
