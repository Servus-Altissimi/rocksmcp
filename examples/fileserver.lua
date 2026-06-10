-- RocksMCP resources demo: a static resource, a template, subscriptions.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local mcp = require("rocksmcp")

local srv = mcp.server{ name = "fileserver", version = "1.0.0" }

srv:resource{
  uri = "example://greeting", name = "Greeting", mime = "text/plain",
  read = function() return "Hello from RocksMCP" end,
}

srv:resource_template{
  uri_template = "example://upper/{word}", name = "Uppercaser", mime = "text/plain",
  read = function(uri, ctx, vars) return vars.word:upper() end,
}

if arg and arg[0] and arg[0]:match("fileserver%.lua$") then
  srv:run()
end

return srv
