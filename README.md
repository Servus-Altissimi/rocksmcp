# RocksMCP

Write [MCP (Model Context Protocol)](https://modelcontextprotocol.io) servers
in Lua. Full server-side protocol: tools, resources (+templates,
subscriptions), prompts, completion, logging, progress, cancellation, and
client interaction (sampling, elicitation, roots) — over stdio, with a
coroutine engine and no event-loop dependency.

Works on Lua 5.1+ and LuaJIT. JSON codec is pluggable (dkjson default,
lua-cjson adapter included).

## Quickstart

```lua
local mcp = require("rocksmcp")

local srv = mcp.server{ name = "echo", version = "1.0.0" }

srv:tool{
  name = "echo",
  description = "Echo the input text back",
  input = mcp.schema.obj({ text = mcp.schema.str("Text to echo") }, { "text" }),
  handler = function(args) return args.text end,
}

srv:run()  -- stdio
```

Register with Claude Code: `claude mcp add my-server -- lua /path/to/server.lua`

## API

### Server

| Call | Purpose |
|---|---|
| `mcp.server{name, version, instructions?}` | create a server |
| `srv:tool{name, description, input, handler, annotations?, output_schema?}` | register a tool; handler `(args, ctx) → string \| table \| {content=..., structuredContent?=...}`. `annotations` (e.g. `{readOnlyHint=true}`) and `output_schema` appear in `tools/list` |
| `srv:resource{uri, name, mime?, description?, read}` | static resource; read `(uri, ctx) → string \| {text=} \| {blob=}` |
| `srv:resource_template{uri_template, name, mime?, read}` | `{var}` templates; read gets `(uri, ctx, vars)` |
| `srv:prompt{name, description?, args?, get}` | prompt; get `(args, ctx) → {messages=...}` |
| `srv:completion(fn)` | argument completion; `fn(ref, argument, ctx, context?) → values` |
| `srv:run()` | serve on stdio |
| `srv:tools_changed() / resources_changed() / prompts_changed()` | list_changed notifications |
| `srv:resource_updated(uri)` | notify subscribers |

### ctx (inside any handler)

| Call | Purpose |
|---|---|
| `ctx.progress(n, total?, msg?)` | progress notification (no-op without client progressToken) |
| `ctx.log(level, msg, data?)` | log via MCP, honors client log level |
| `ctx.sample{...}` | ask the client's LLM (yields until reply) |
| `ctx.elicit{...}` | ask the client's user (yields until reply) |
| `ctx.roots()` | client filesystem roots (yields) |
| `ctx.cancelled()` | cooperative cancellation check |
| `ctx.client` | client info + capabilities |

### Schema builders

`mcp.schema.obj(props, required, desc?)`, `.str/.num/.int/.bool(desc?, {min=, max=, default=, pattern=})`,
`.arr(items, desc?)`, `.enum(values, desc?)`.

### JSON codec

`mcp.use_json("rocksmcp.json.cjson")` or pass a codec table
`{name, encode, decode, null, array, object}`. Default: dkjson.

## Errors

Raise `error("message", 0)` in handlers — tools get `isError` results, other
handlers get JSON-RPC errors. Raise `error({code=-32602, message="..."}, 0)`
for a specific JSON-RPC code.
Tool arguments are passed to handlers as-decoded — validate inputs in your handler; the library does not enforce inputSchema.

## Development

```sh
luarocks --lua-version 5.4 --tree .rocks install dkjson
luarocks --lua-version 5.4 --tree .rocks install busted
scripts/test.sh        # busted suite
scripts/compat.sh      # smoke under luajit / other interpreters
```

Examples: `examples/echo.lua`, `examples/fileserver.lua`.
