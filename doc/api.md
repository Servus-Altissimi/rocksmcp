# RocksMCP API reference

Everything a server author (human or model) needs, on one page. Every call
below is exported; nothing else is public. The source carries LuaLS
annotations (`---@class rocksmcp.ToolDef` and friends), so an editor or agent
with lua-language-server gets completion and type checks too.

Installed with luarocks, this file sits in the rock's `doc/` folder:
`luarocks doc --list rocksmcp` prints the path.

## Shape of a server

```lua
local mcp = require("rocksmcp")
local S = mcp.schema

local srv = mcp.server{
  name = "notes", version = "1.0.0",
  instructions = "Call notes{action='list'} first; ids come from there.",
  validate_input = true,        -- refuse arguments that break the input schema
  max_result_bytes = 256 * 1024, -- refuse oversized results with a hint
}

srv:tool{
  name = "notes",
  description = "List, read and delete notes. Pass every id in one call.",
  input = S.obj({
    ids = S.arr(S.str("Note id"), "Ids for get and delete", { min_items = 1 }),
    confirm = S.bool("Required true for delete"),
  }, nil, nil, { additional = false }),
  action_order = { "list", "get", "delete" },
  actions = {
    list = function(args, ctx) return store.list() end,
    get = function(args) return store.get(args.ids) end,
    delete = function(args)
      if not args.confirm then error("delete needs confirm=true", 0) end
      return store.delete(args.ids)
    end,
  },
  annotations = { destructiveHint = true },
}

srv:run()
```

## mcp

| Call | Does |
|---|---|
| `mcp.server(opts)` | new server. `opts`: `name`, `version` (required), `instructions?`, `validate_input?` (default false), `max_result_bytes?` (default no cap). Unknown keys raise. |
| `mcp.result{content?, structuredContent?, isError?}` | a complete tool result, sent as-is. Use it for several content blocks, images, or `isError` without raising. |
| `mcp.text(s)` | a text content block `{type="text", text=s}` |
| `mcp.user_text(s)`, `mcp.assistant_text(s)` | prompt messages |
| `mcp.schema` | the schema builders below |
| `mcp.json` | the active codec facade: `encode`, `decode`, `null()`, `array(t)`, `object(t)` |
| `mcp.use_json(codec)` | swap the codec (`"rocksmcp.json.cjson"` or a table); returns the previous one |
| `mcp.set_diagnostics(fn)` | where crash tracebacks and warnings go (default stderr); returns the previous function |
| `mcp.VERSION` | library version string |

## srv:tool(def)

| Field | Type | Notes |
|---|---|---|
| `name` | string | letters, digits, `_ - .`; unique |
| `description` | string | the model's only manual; missing one warns on stderr |
| `input` | object schema | `S.obj(...)`; omit for no arguments |
| `handler` | `function(args, ctx)` | or `actions`, not both |
| `actions` | `{ name = function(args, ctx) }` | adds a required `action` enum to `input` and dispatches on it |
| `action_order` | string[] | order of the enum (default sorted); must list every action |
| `annotations` | table | `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`, `title` |
| `output_schema` | object schema | a table result is also sent as `structuredContent` |
| `validate` | boolean | overrides the server's `validate_input` for this tool |
| `title` | string | shorthand for `annotations.title` |

A malformed definition raises at the `srv:tool` line with every problem in
one message, typos included: `inputSchema` says "did you mean 'input'", `fn`
says "did you mean 'handler'".

### What a handler returns

| Return | Client gets |
|---|---|
| string | one text block |
| table (any data) | one text block holding the table as JSON; also `structuredContent` when the tool has `output_schema` |
| `mcp.result{...}` | exactly that result |
| nil | `{}` as text |

A plain table is always data, even with a `content` key, except the
pre-0.1.2 form `{ content = { {type=...}, ... } }`, which still passes through.
Prefer `mcp.result` for new code.

Note: dkjson treats a numeric `n` field as an array length (`{ n = 1 }`
encodes as `[null]`). Name counts something else (`count`, `total`).

### Errors

| Raise | Client gets |
|---|---|
| `error("msg", 0)` | tool result `isError = true`, text `msg`; nothing logged |
| `error("msg")`, or a runtime fault | same clean text for the client, plus a full traceback through `mcp.set_diagnostics` (stderr by default) |
| `error({ code = -32602, message = "..." }, 0)` | a JSON-RPC error with that code |

Use `error(msg, 0)` for expected failures (not found, bad input, upstream
4xx); let bugs raise normally so their traceback reaches stderr.

### Input validation

With `validate_input = true` (or `validate = true` on a tool), arguments are
checked against `input` before the handler runs. On failure the client gets
an `isError` result listing every problem and the handler is not called:

```
Invalid arguments for notes:
- arguments.ids[0] must be string, got integer
- arguments.colour is not a known field (known: action, confirm, ids)
Nothing was done. Fix the arguments and call again.
```

Checked: `type`, `enum`, `required`, `minimum`/`maximum`,
`minLength`/`maxLength` (characters, not bytes), `minItems`/`maxItems`,
`items`, `properties`, `additionalProperties`. Not checked: `pattern`,
`oneOf`/`anyOf`, `$ref`. A JSON `null` on an optional field counts as absent.
Without validation, handlers get arguments as decoded and must check them.

### Result size cap

With `max_result_bytes`, a result whose text (plus `structuredContent`) is
larger becomes an `isError` result telling the model to ask for less (smaller
limit, narrower filter, fewer fields). The handler has already run, so cap
reads, not writes: return compact write results.

## ctx (second handler argument)

| Call | Does |
|---|---|
| `ctx.progress(n, total?, msg?)` | progress notification; returns false when the client sent no progress token |
| `ctx.log(level, msg, data?)` | MCP log message; honours the client's level (`debug` ... `emergency`) |
| `ctx.sample(params)` | ask the client's model (`sampling/createMessage`); waits for the reply |
| `ctx.elicit(params)` | ask the client's user (`elicitation/create`); waits |
| `ctx.roots()` | the client's roots list; waits |
| `ctx.cancelled()` | true once the client cancelled this request |
| `ctx.client` | `{ info, capabilities, protocolVersion }` |

`sample`, `elicit` and `roots` raise `"client does not support ..."` when the
client lacks the capability. They yield the handler's coroutine, so call them
only from the handler itself (not from inside a `pcall` on Lua 5.1).

## mcp.schema

| Builder | JSON Schema |
|---|---|
| `S.str(desc?, opts?)` | string; opts `min_length`, `max_length`, `pattern`, `default` |
| `S.int(desc?, opts?)`, `S.num(desc?, opts?)` | integer / number; opts `min`, `max`, `default` |
| `S.bool(desc?, opts?)` | boolean; opt `default` |
| `S.enum(values, desc?)` | string limited to `values` |
| `S.arr(items, desc?, opts?)` | array of `items`; opts `min_items`, `max_items` |
| `S.obj(props?, required?, desc?, opts?)` | object; opt `additional` = `false` (reject unknown keys) or a schema |
| `S.map(values, desc?)` | object with free keys, each value matching `values` |
| `S.any(desc?)` | any JSON value |
| `S.nullable(schema)` | `schema` or `null` |
| `S.validate(schema, value, root?)` | `true`, or `false, problems` (strings like `arguments.limit must be integer, got string`) |

Every builder returns a fresh table; reuse a builder call, not a table you
then mutate.

## Resources, prompts, completion

| Call | Notes |
|---|---|
| `srv:resource{uri, name, read, mime?, description?}` | `read(uri, ctx)` returns a string, `{text=}`, `{blob=}` (base64) or `{contents=...}` |
| `srv:resource_template{uri_template, name, read, mime?, description?}` | `{var}` placeholders; `read(uri, ctx, vars)` |
| `srv:prompt{name, get, description?, args?}` | `args` = `{ {name, description?, required?} }`; `get(args, ctx)` returns `{ messages = {...}, description? }` |
| `srv:completion(fn)` | `fn(ref, argument, ctx, context?)` returns values, or `{values, total?, hasMore?}`; capped at 100 |
| `srv:tools_changed()`, `srv:resources_changed()`, `srv:prompts_changed()` | list_changed notifications |
| `srv:resource_updated(uri)` | notifies subscribers of `uri` |
| `srv:run()` | serve newline-delimited JSON-RPC on stdin/stdout |

stdout belongs to the protocol: never `print` in a server. Write debug
output to stderr (`io.stderr:write`) or use `ctx.log`.

## Testing: rocksmcp.testing

```lua
local testing = require("rocksmcp.testing")

describe("notes", function()
  it("lists", function()
    local c = testing.client(require("notes.server")())
    local r = c:call("notes", { action = "list" })
    assert.is_nil(r.isError, r.text)
    assert.equal(3, #r.data)
  end)
end)
```

| Call | Does |
|---|---|
| `testing.client(srv, opts?)` | a fresh in-process session, already initialized. opts: `init` (false to skip the handshake), `capabilities`, `protocol_version`, `on_request(method, params)` answering sampling, elicitation and roots (return a result, or `nil, {code, message}`) |
| `c:call(name, args?)` | the tool result plus `text` (all text blocks joined) and `data` (that text decoded as JSON, when it is JSON). A JSON-RPC error raises. |
| `c:request(method, params?)` | the raw JSON-RPC response `{result}` or `{error}` |
| `c:list_tools()` | every tool across pages, as `tools/list` returns them |
| `c:tool(name)` | one `tools/list` entry, or nil |
| `c.notifications` | every notification the server sent |
| `c.initialize_result` | the server's initialize result |

## Pitfalls

- Empty tables: `{}` encodes as `[]` unless tagged. Return `mcp.json.object({})`
  for an empty object and `mcp.json.array(t)` for a list that may be empty.
- `null` from the client decodes to `mcp.json.null()`, not `nil`.
- Values decoded under one codec must not be re-encoded under another.
- Lua patterns are not regexes: `pattern` in a schema is sent to clients
  as-is and never checked here.
