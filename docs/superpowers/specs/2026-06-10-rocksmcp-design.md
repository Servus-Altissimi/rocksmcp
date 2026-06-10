# RocksMCP Design — Phase 1: Core Engine + Stdio

Date: 2026-06-10
Status: Approved

## Goal

A standalone Lua library that makes writing MCP servers in Lua easy. Seeded
from AnkiMCP's proven protocol code (`src/mcp.lua`, `src/schema.lua`,
`util.array/object`), extended to the full MCP specification (rev 2025-06-18,
accepting 2025-03-26 clients via version negotiation).

## Decisions (made with user)

- **Scope:** full MCP spec, phased. Phase 1 (this spec): transport-agnostic
  protocol engine, stdio transport, all server primitives (tools, resources,
  resource templates, subscriptions, prompts, completion), logging, progress,
  cancellation, pagination, and server→client requests (sampling,
  elicitation, roots). Phase 2 (separate spec): Streamable HTTP transport.
  Phase 3 (separate spec): migrate AnkiMCP to depend on RocksMCP.
- **Compatibility:** Lua 5.1+ including LuaJIT. No `goto`, no integer
  operators, no `utf8` stdlib; `table.unpack or unpack` shims.
- **JSON:** pluggable codec, dkjson default. Codec interface
  `{encode, decode, null, array, object}`; shipped adapters for dkjson and
  lua-cjson; `mcp.use_json(codec)` to swap.
- **Architecture:** coroutine engine. Each request runs in its own coroutine;
  server→client calls yield until the matching response arrives. No event-loop
  dependency. Single-threaded; concurrency via parking.
- **Distribution:** luarocks-publishable rockspec, MIT. Repo:
  `~/projects/rocksmcp`, namespace `rocksmcp.*`.

## Public API

```lua
local mcp = require("rocksmcp")

local srv = mcp.server{ name = "demo", version = "1.0.0", instructions = "..." }

srv:tool{
  name = "greet", description = "Say hello",
  input = mcp.schema.obj({ who = mcp.schema.str("Name") }, { "who" }),
  handler = function(args, ctx)
    ctx.progress(0.5)
    ctx.log("info", "greeting…")
    return { text = "hello " .. args.who }  -- table → JSON text content; string → as-is
  end,
}

srv:resource{ uri = "demo://readme", name = "README", mime = "text/plain",
  read = function(uri, ctx) return "contents" end }

srv:resource_template{ uri_template = "demo://files/{path}", name = "Files",
  read = function(uri, ctx) ... end }

srv:prompt{ name = "review", description = "...",
  args = { { name = "lang", required = true } },
  get = function(args, ctx) return { messages = { mcp.user_text("Review " .. args.lang) } } end }

srv:completion(function(ref, argument, ctx) return { "a", "b" } end)

srv:run()  -- stdio transport
```

### ctx (per request)

| Method | Behavior |
|---|---|
| `ctx.progress(n, total?, msg?)` | emits `notifications/progress` (only when the request carried a progressToken) |
| `ctx.log(level, msg, data?)` | emits `notifications/message`, honoring the client-set log level |
| `ctx.sample{...}` | sends `sampling/createMessage`, yields, returns client's response |
| `ctx.elicit{...}` | sends `elicitation/create`, yields, returns user's answer |
| `ctx.roots()` | sends `roots/list`, yields, returns roots |
| `ctx.cancelled()` | true after `notifications/cancelled` for this request (cooperative) |
| `ctx.client` | negotiated client info + capabilities |

Server→client calls error cleanly if the client never declared the matching
capability.

### Server-initiated notifications

`srv:tools_changed()`, `srv:resources_changed()`, `srv:resource_updated(uri)`,
`srv:prompts_changed()`. Resource subscriptions (`resources/subscribe`/
`unsubscribe`) tracked per session; `resource_updated` notifies only
subscribers. Capabilities are computed automatically from what is registered
(e.g. `resources.subscribe = true` only if any resource is registered;
`completions` only if a completion handler exists).

## Modules

```
rocksmcp/init.lua            facade: mcp.server, mcp.schema, mcp.use_json,
                             content helpers (mcp.user_text, mcp.text, ...)
rocksmcp/json.lua            codec interface + default resolution
rocksmcp/json/dkjson.lua     default adapter
rocksmcp/json/cjson.lua      lua-cjson adapter
rocksmcp/protocol.lua        transport-agnostic engine: session state machine
                             (uninitialized → initialized → operating),
                             JSON-RPC 2.0 validation, dispatch, coroutine
                             scheduler, outgoing-request id correlation,
                             cancellation, version negotiation, error codes
rocksmcp/server.lua          registration API, capability computation, method
                             handlers for tools/resources/prompts/completion,
                             cursor pagination for all list endpoints
rocksmcp/schema.lua          obj/str/num/int/bool/arr/enum builders with
                             description/min/max/default/pattern, 5.1-safe
rocksmcp/transport/stdio.lua line loop: response lines resume parked
                             coroutines; request/notification lines dispatch
examples/echo.lua            minimal tool server (~20 lines)
examples/fileserver.lua      resources + templates + subscriptions demo
```

The engine core is `feed(line) → zero or more out-lines` — pure, no IO. That
is what makes the HTTP transport a drop-in later and the engine testable
without spawning processes.

## Coroutine semantics

Every `tools/call`, `resources/read`, `prompts/get`, `completion/complete`
runs in a fresh coroutine. Return → response emitted. `ctx.sample()` →
engine emits `sampling/createMessage` with a generated id, parks the
coroutine keyed by that id; when the response line arrives, resumes with the
result. `notifications/cancelled` sets the cancelled flag on the matching
ctx; handlers poll cooperatively. Handler errors become MCP
`isError:true` results with Lua location prefixes stripped (carried over from
AnkiMCP).

## Inherited from AnkiMCP (proven behavior)

Batch rejection (-32600), parse error with null id (-32700), unknown method
(-32601), unknown tool (-32602), notifications never answered, registration-
order tool listing, `error(msg, 0)` convention, empty-container `[]`/`{}`
discipline via codec `array`/`object` tagging, stdout flush per message,
stderr for diagnostics.

New protocol behavior: version negotiation (echo client's version when
supported, else offer ours), double-initialize rejection, requests before
initialize rejected (except ping), graceful unknown-notification tolerance.

## Error handling

- All library-raised errors use `error(msg, 0)`.
- Handler failures → `isError` results, never protocol errors.
- Protocol violations → JSON-RPC error codes per spec.
- Server→client request timeout: none in phase 1 (stdio client is the only
  reader; a dead client ends the session at EOF anyway). Documented.

## Testing

busted. Engine tests feed JSON-RPC lines and assert emitted lines — no
processes, no IO. Bidirectional session tests: sampling round-trip
(request parked, response resumes), cancellation mid-flight, subscription
update fan-out, pagination cursors, version negotiation, capability gating.
Adapter tests for dkjson (always) and cjson (skipped when not installed).
Suite runs on Lua 5.4 locally; 5.1/LuaJIT smoke run when interpreters are
present, otherwise compatibility is by construction (no 5.2+ features) and
checked in review.

## Distribution

`rocksmcp-0.1.0-1.rockspec` (builtin build, dkjson dependency, lua >= 5.1),
MIT LICENSE, README with quickstart + API reference + ctx table, examples/
runnable against any MCP client. Publishing to luarocks.org is a manual user
step; check name availability before first release.
