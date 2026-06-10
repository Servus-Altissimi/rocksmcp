# RocksMCP Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build RocksMCP — a Lua 5.1+ library for writing MCP servers: pluggable JSON codec, coroutine protocol engine (full MCP rev 2025-06-18), stdio transport, busted tests, examples, rockspec.

**Architecture:** Transport-agnostic engine (`feed(line) → out-lines`, pure, no IO). Each request runs in a coroutine; server→client calls (`ctx.sample`/`ctx.elicit`/`ctx.roots`) yield until the matching response line arrives. Registration API (`srv:tool{}` etc.) in a facade over the engine. Spec: `docs/superpowers/specs/2026-06-10-rocksmcp-design.md`.

**Tech Stack:** Lua 5.1-compatible source (no `goto`, no integer ops, no `utf8`, no pcall-across-yield, `table.unpack or unpack` shim). Dev/test under `lua5.4` + busted from project-local `.rocks` (already installed: dkjson 2.10, busted 2.3.0, luasocket). `luajit` (= Lua 5.1 semantics) available at `/usr/bin/luajit` for the compat smoke test. lua-cjson NOT installed — its adapter test must skip gracefully.

**Critical 5.1 constraint:** plain Lua 5.1 cannot `coroutine.yield` across a `pcall` boundary. Therefore handler errors are caught via `coroutine.resume` returning `false` — NEVER wrap handlers in `pcall` inside the coroutine body.

**Conventions:** all library errors `error(msg, 0)` (or `error({code=..., message=...}, 0)` for JSON-RPC-coded errors). Tests run via `scripts/test.sh` from repo root. All test/run commands assume repo root `/home/user/projects/rocksmcp`. Never add Claude attribution trailers to commits.

---

### Task 1: Scaffold, test runner, rockspec, sanity

**Files:**
- Create: `.gitignore`, `scripts/test.sh`, `rocksmcp-0.1.0-1.rockspec`, `spec/sanity_spec.lua`

- [ ] **Step 1: Write `.gitignore`**

```
.rocks/
```

- [ ] **Step 2: Write `scripts/test.sh`** then `chmod +x scripts/test.sh`

```sh
#!/bin/sh
set -e
cd "$(dirname "$0")/.."
eval "$(luarocks --lua-version 5.4 --tree .rocks path)"
export LUA_PATH="./?.lua;./src/?.lua;./src/?/init.lua;$LUA_PATH"
exec .rocks/bin/busted "$@"
```

(`./?.lua` lets specs require `spec.helper`; `./src/?.lua` maps `rocksmcp.json` → `src/rocksmcp/json.lua`.)

- [ ] **Step 3: Write `rocksmcp-0.1.0-1.rockspec`**

```lua
package = "rocksmcp"
version = "0.1.0-1"
source = { url = "git+https://example.invalid/rocksmcp.git" }
description = {
  summary = "Write MCP (Model Context Protocol) servers in Lua",
  detailed = "Coroutine-based MCP server library: tools, resources, prompts, completion, logging, progress, sampling/elicitation, stdio transport. Lua 5.1+ and LuaJIT.",
  license = "MIT",
}
dependencies = {
  "lua >= 5.1",
  "dkjson >= 2.5",
}
build = {
  type = "builtin",
  modules = {
    ["rocksmcp"] = "src/rocksmcp/init.lua",
    ["rocksmcp.json"] = "src/rocksmcp/json.lua",
    ["rocksmcp.json.dkjson"] = "src/rocksmcp/json/dkjson.lua",
    ["rocksmcp.json.cjson"] = "src/rocksmcp/json/cjson.lua",
    ["rocksmcp.protocol"] = "src/rocksmcp/protocol.lua",
    ["rocksmcp.server"] = "src/rocksmcp/server.lua",
    ["rocksmcp.schema"] = "src/rocksmcp/schema.lua",
    ["rocksmcp.transport.stdio"] = "src/rocksmcp/transport/stdio.lua",
  },
}
```

- [ ] **Step 4: Write `spec/sanity_spec.lua`**

```lua
describe("toolchain", function()
  it("loads dkjson with null sentinel", function()
    local json = require("dkjson")
    assert.is_not_nil(json.null)
    local d = json.decode("[1,null,2]", 1, json.null)
    assert.equal(3, #d)
  end)
end)
```

- [ ] **Step 5: Run** `scripts/test.sh` — expect `1 success / 0 failures`

- [ ] **Step 6: Commit**

```bash
git add .gitignore scripts/test.sh rocksmcp-0.1.0-1.rockspec spec/sanity_spec.lua
git commit -m "chore: scaffold, test runner, rockspec"
```

---

### Task 2: JSON codec facade + adapters

**Files:**
- Create: `src/rocksmcp/json.lua`, `src/rocksmcp/json/dkjson.lua`, `src/rocksmcp/json/cjson.lua`
- Test: `spec/json_spec.lua`

- [ ] **Step 1: Write failing tests `spec/json_spec.lua`**

```lua
local json = require("rocksmcp.json")

describe("json facade", function()
  it("defaults to dkjson and round-trips", function()
    local s = json.encode({ a = 1, b = json.array({ 1, 2 }) })
    local t = json.decode(s)
    assert.equal(1, t.a)
    assert.equal(2, t.b[2])
  end)

  it("encodes tagged empty containers distinctly", function()
    assert.equal("[]", json.encode(json.array({})))
    assert.equal("{}", json.encode(json.object({})))
  end)

  it("decodes null to a stable sentinel", function()
    local t = json.decode('{"x":null,"l":[1,null]}')
    assert.equal(json.null(), t.x)
    assert.equal(json.null(), t.l[2])
    assert.equal(2, #t.l)
  end)

  it("encodes the sentinel back to null", function()
    assert.equal("[null]", json.encode(json.array({ json.null() })))
  end)

  it("returns nil on invalid input", function()
    assert.is_nil(json.decode("{nope"))
  end)

  it("can swap codecs and restore", function()
    local fake = {
      name = "fake",
      encode = function() return "FAKE" end,
      decode = function() return { fake = true } end,
      null = {},
      array = function(t) return t end,
      object = function(t) return t end,
    }
    local prev = json.use(fake)
    assert.equal("FAKE", json.encode({}))
    json.use(prev)
    assert.equal("[]", json.encode(json.array({})))
  end)
end)

describe("cjson adapter", function()
  local ok = pcall(require, "cjson")
  if not ok then
    pending("lua-cjson not installed; adapter untested here", function() end)
    return
  end
  it("round-trips with null sentinel", function()
    local cj = require("rocksmcp.json.cjson")
    local t = cj.decode('{"x":null}')
    assert.equal(cj.null, t.x)
    assert.is_string(cj.encode({ a = 1 }))
  end)
end)
```

- [ ] **Step 2: Run** `scripts/test.sh spec/json_spec.lua` — expect FAIL `module 'rocksmcp.json' not found`

- [ ] **Step 3: Write `src/rocksmcp/json/dkjson.lua`**

```lua
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
```

- [ ] **Step 4: Write `src/rocksmcp/json/cjson.lua`**

```lua
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
```

- [ ] **Step 5: Write `src/rocksmcp/json.lua`**

```lua
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
```

- [ ] **Step 6: Run** `scripts/test.sh spec/json_spec.lua` — expect PASS (6 successes, 1 pending for cjson)

- [ ] **Step 7: Commit**

```bash
git add src/rocksmcp/json.lua src/rocksmcp/json spec/json_spec.lua
git commit -m "feat: pluggable JSON codec with dkjson and cjson adapters"
```

---

### Task 3: Schema builders

**Files:**
- Create: `src/rocksmcp/schema.lua`
- Test: `spec/schema_spec.lua`

- [ ] **Step 1: Write failing tests `spec/schema_spec.lua`**

```lua
local S = require("rocksmcp.schema")
local json = require("rocksmcp.json")

describe("schema", function()
  it("builds object schemas with required arrays", function()
    local sch = S.obj({ who = S.str("Name") }, { "who" }, "Args")
    assert.equal("object", sch.type)
    assert.equal("Args", sch.description)
    assert.same({ "who" }, sch.required)
    assert.equal("string", sch.properties.who.type)
  end)

  it("omits empty required and encodes properties as object", function()
    local sch = S.obj({}, {})
    assert.is_nil(sch.required)
    assert.equal('{"type":"object","properties":{}}',
      json.encode({ type = sch.type, properties = sch.properties }):gsub("%s", ""))
  end)

  it("supports opts on primitives", function()
    local n = S.num("Count", { min = 1, max = 10, default = 5 })
    assert.equal(1, n.minimum)
    assert.equal(10, n.maximum)
    assert.equal(5, n.default)
    local i = S.int("Index")
    assert.equal("integer", i.type)
    local s = S.str("Id", { pattern = "^%w+$" })
    assert.equal("^%w+$", s.pattern)
  end)

  it("builds arrays and enums", function()
    local a = S.arr(S.str(), "List")
    assert.equal("array", a.type)
    assert.equal("string", a.items.type)
    local e = S.enum({ "x", "y" }, "Choice")
    assert.same({ "x", "y" }, e.enum)
  end)
end)
```

- [ ] **Step 2: Run** `scripts/test.sh spec/schema_spec.lua` — expect FAIL `module 'rocksmcp.schema' not found`

- [ ] **Step 3: Write `src/rocksmcp/schema.lua`**

```lua
local json = require("rocksmcp.json")

local S = {}

local function prim(jtype)
  return function(desc, opts)
    opts = opts or {}
    return {
      type = jtype,
      description = desc,
      minimum = opts.min,
      maximum = opts.max,
      default = opts.default,
      pattern = opts.pattern,
    }
  end
end

S.str = prim("string")
S.num = prim("number")
S.int = prim("integer")
S.bool = prim("boolean")

function S.obj(properties, required, desc)
  local sch = {
    type = "object",
    properties = json.object(properties or {}),
    description = desc,
  }
  if required and #required > 0 then
    sch.required = json.array(required)
  end
  return sch
end

function S.arr(items, desc)
  return { type = "array", items = items, description = desc }
end

function S.enum(values, desc)
  return { type = "string", enum = json.array(values), description = desc }
end

return S
```

- [ ] **Step 4: Run** `scripts/test.sh spec/schema_spec.lua` — expect PASS

- [ ] **Step 5: Commit**

```bash
git add src/rocksmcp/schema.lua spec/schema_spec.lua
git commit -m "feat: JSON-schema builders"
```

---

### Task 4: Protocol core — lifecycle, framing, errors

**Files:**
- Create: `src/rocksmcp/protocol.lua`, `spec/helper.lua`
- Test: `spec/protocol_spec.lua`

This task implements everything EXCEPT coroutine method dispatch (Task 5 adds it). The `methods` table is accepted but a lookup miss simply yields -32601 for now.

- [ ] **Step 1: Write `spec/helper.lua`**

```lua
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
```

- [ ] **Step 2: Write failing tests `spec/protocol_spec.lua`**

```lua
local protocol = require("rocksmcp.protocol")
local json = require("rocksmcp.json")
local H = require("spec.helper")

local function new_session(opts)
  opts = opts or {}
  return protocol.new({
    info = { name = "t", version = "0" },
    instructions = opts.instructions,
    capabilities = opts.capabilities or function() return json.object({}) end,
    methods = opts.methods or {},
  })
end

describe("protocol lifecycle", function()
  it("negotiates a supported protocol version", function()
    local res = H.init(new_session(), "2025-03-26")
    assert.equal("2025-03-26", res.protocolVersion)
    assert.equal("t", res.serverInfo.name)
  end)

  it("falls back to its own version for unknown client versions", function()
    local res = H.init(new_session(), "2099-01-01")
    assert.equal("2025-06-18", res.protocolVersion)
  end)

  it("includes instructions when set", function()
    local res = H.init(new_session({ instructions = "be nice" }))
    assert.equal("be nice", res.instructions)
  end)

  it("rejects double initialize", function()
    local s = new_session()
    H.init(s)
    local r = H.rpc(s, { jsonrpc = "2.0", id = 9, method = "initialize",
      params = { protocolVersion = "2025-06-18" } })
    assert.equal(-32600, r[1].error.code)
  end)

  it("rejects requests before initialize except ping", function()
    local s = new_session()
    local pong = H.rpc(s, { jsonrpc = "2.0", id = 1, method = "ping" })
    assert.is_table(pong[1].result)
    local r = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "tools/list" })
    assert.equal(-32002, r[1].error.code)
  end)

  it("answers ping after init", function()
    local s = new_session()
    H.init(s)
    local r = H.rpc(s, { jsonrpc = "2.0", id = 5, method = "ping" })
    assert.is_table(r[1].result)
  end)

  it("ignores notifications and unknown notifications", function()
    local s = new_session()
    H.init(s)
    assert.same({}, s:feed(json.encode({ jsonrpc = "2.0", method = "notifications/whatever" })))
  end)

  it("errors on parse failure with null id", function()
    local s = new_session()
    local r = json.decode(s:feed("{nope")[1])
    assert.equal(-32700, r.error.code)
  end)

  it("rejects batches", function()
    local s = new_session()
    local r = json.decode(s:feed('[{"jsonrpc":"2.0","id":1,"method":"ping"}]')[1])
    assert.equal(-32600, r.error.code)
  end)

  it("errors on unknown method", function()
    local s = new_session()
    H.init(s)
    local r = H.rpc(s, { jsonrpc = "2.0", id = 3, method = "bogus" })
    assert.equal(-32601, r[1].error.code)
  end)

  it("sets log level via logging/setLevel", function()
    local s = new_session()
    H.init(s)
    local r = H.rpc(s, { jsonrpc = "2.0", id = 4, method = "logging/setLevel",
      params = { level = "warning" } })
    assert.is_table(r[1].result)
    assert.equal("warning", s.log_level)
    local bad = H.rpc(s, { jsonrpc = "2.0", id = 5, method = "logging/setLevel",
      params = { level = "loud" } })
    assert.equal(-32602, bad[1].error.code)
  end)

  it("exposes client info after init", function()
    local s = new_session()
    H.init(s)
    assert.equal("test", s.client.info.name)
  end)

  it("queues server notifications for the transport", function()
    local s = new_session()
    H.init(s)
    s:notify("notifications/tools/list_changed", nil)
    local out = s:take_output()
    assert.equal(1, #out)
    assert.equal("notifications/tools/list_changed", json.decode(out[1]).method)
  end)
end)
```

- [ ] **Step 3: Run** `scripts/test.sh spec/protocol_spec.lua` — expect FAIL `module 'rocksmcp.protocol' not found`

- [ ] **Step 4: Write `src/rocksmcp/protocol.lua`**

```lua
local json = require("rocksmcp.json")

local M = {}

M.SUPPORTED_VERSIONS = { ["2025-06-18"] = true, ["2025-03-26"] = true }
M.DEFAULT_VERSION = "2025-06-18"

M.LOG_RANK = {
  debug = 1, info = 2, notice = 3, warning = 4,
  error = 5, critical = 6, alert = 7, emergency = 8,
}

function M.result_msg(id, result)
  return { jsonrpc = "2.0", id = id, result = result }
end

function M.error_msg(id, code, message, data)
  return { jsonrpc = "2.0", id = id, error = { code = code, message = message, data = data } }
end

-- strip "path/to/file.lua:NN: " prefixes from handler errors
function M.clean_err(e)
  if type(e) == "string" then
    return (e:gsub("^.-%.lua:%d+: ", ""))
  end
  return e
end

local function reqkey(id)
  return type(id) .. ":" .. tostring(id)
end

local Session = {}
Session.__index = Session

-- opts: info {name,version}, instructions?, capabilities (function -> table),
--       methods { [name] = def } where def = { run = f(params, ctx) -> result,
--       on_error = f(id, err) -> response msg (optional) }
function M.new(opts)
  return setmetatable({
    info = opts.info,
    instructions = opts.instructions,
    get_capabilities = opts.capabilities,
    methods = opts.methods or {},
    initialized = false,
    ready = false,
    client = nil,
    log_level = "debug",
    inflight = {},
    pending_out = {},
    next_out_id = 0,
    current_entry = nil,
    out = {},
  }, Session)
end

function Session:queue(msg)
  self.out[#self.out + 1] = json.encode(msg)
end

function Session:notify(method, params)
  self:queue({ jsonrpc = "2.0", method = method, params = params })
end

function Session:take_output()
  local o = self.out
  self.out = {}
  return o
end

local function default_on_error(id, err)
  if type(err) == "table" and err.code then
    return M.error_msg(id, err.code, err.message or "error", err.data)
  end
  return M.error_msg(id, -32603, tostring(err))
end

-- resume an entry's coroutine; emit its response when it completes
function Session:step(entry, ...)
  self.current_entry = entry
  local ok, res = coroutine.resume(entry.co, ...)
  self.current_entry = nil
  if ok and coroutine.status(entry.co) == "suspended" then
    return -- parked awaiting a client response
  end
  self.inflight[entry.key] = nil
  if entry.cancelled then return end -- spec: no response after cancellation
  if ok then
    self:queue(M.result_msg(entry.id, res))
  else
    local handler = entry.on_error or default_on_error
    self:queue(handler(entry.id, M.clean_err(res)))
  end
end

-- send a request to the client and park until its response arrives.
-- Must be called from inside a request coroutine.
function Session:client_request(method, params)
  local entry = self.current_entry
  if not entry or coroutine.running() ~= entry.co then
    error("client requests are only allowed inside a request handler", 0)
  end
  self.next_out_id = self.next_out_id + 1
  local id = self.next_out_id
  self.pending_out[id] = entry
  self:queue({ jsonrpc = "2.0", id = id, method = method, params = params })
  local result, err = coroutine.yield()
  if err ~= nil then
    error("client returned error for " .. method .. ": "
      .. tostring(type(err) == "table" and err.message or err), 0)
  end
  return result
end

function Session:make_ctx(id, params)
  local session = self
  local meta = type(params) == "table" and type(params._meta) == "table" and params._meta or {}
  local token = meta.progressToken
  local ctx = { client = nil, _cancelled = false }

  function ctx.progress(progress, total, message)
    if token == nil then return false end
    session:notify("notifications/progress", {
      progressToken = token, progress = progress, total = total, message = message,
    })
    return true
  end

  function ctx.log(level, message, data)
    local rank = M.LOG_RANK[level]
    if not rank then error("unknown log level: " .. tostring(level), 0) end
    if rank < (M.LOG_RANK[session.log_level] or 1) then return false end
    session:notify("notifications/message", {
      level = level,
      data = data ~= nil and { message = message, data = data } or message,
    })
    return true
  end

  function ctx.cancelled()
    return ctx._cancelled == true
  end

  local function gated(cap_key, method)
    return function(req_params)
      local caps = (session.client and session.client.capabilities) or {}
      if caps[cap_key] == nil then
        error("client does not support " .. cap_key, 0)
      end
      return session:client_request(method, req_params)
    end
  end

  ctx.sample = gated("sampling", "sampling/createMessage")
  ctx.elicit = gated("elicitation", "elicitation/create")
  local roots_req = gated("roots", "roots/list")
  function ctx.roots()
    local res = roots_req(json.object({}))
    return (res or {}).roots or {}
  end

  ctx.client = session.client
  return ctx
end

function Session:handle_response(msg)
  local entry = self.pending_out[msg.id]
  if not entry then return end
  self.pending_out[msg.id] = nil
  local err = msg.error
  if err == json.null() then err = nil end
  local result = msg.result
  if result == json.null() then result = nil end
  if err ~= nil then
    self:step(entry, nil, err)
  else
    self:step(entry, result, nil)
  end
end

function Session:handle_message(msg)
  local method, id = msg.method, msg.id
  local params = msg.params
  if params == json.null() then params = nil end
  params = params or {}

  -- notifications
  if id == nil then
    if method == "notifications/cancelled" then
      local entry = params.requestId ~= nil and self.inflight[reqkey(params.requestId)] or nil
      if entry then
        entry.cancelled = true
        if entry.ctx then entry.ctx._cancelled = true end
      end
    elseif method == "notifications/initialized" then
      self.ready = true
    end
    return -- all other notifications ignored
  end

  -- requests
  if method == "ping" then
    self:queue(M.result_msg(id, json.object({})))
    return
  end

  if method == "initialize" then
    if self.initialized then
      self:queue(M.error_msg(id, -32600, "Server already initialized"))
      return
    end
    self.initialized = true
    self.client = {
      info = params.clientInfo,
      capabilities = params.capabilities or {},
      protocolVersion = params.protocolVersion,
    }
    local v = M.SUPPORTED_VERSIONS[params.protocolVersion]
      and params.protocolVersion or M.DEFAULT_VERSION
    self.negotiated_version = v
    self:queue(M.result_msg(id, {
      protocolVersion = v,
      capabilities = self.get_capabilities and self.get_capabilities() or json.object({}),
      serverInfo = self.info,
      instructions = self.instructions,
    }))
    return
  end

  if not self.initialized then
    self:queue(M.error_msg(id, -32002, "Server not initialized"))
    return
  end

  if method == "logging/setLevel" then
    if M.LOG_RANK[params.level] then
      self.log_level = params.level
      self:queue(M.result_msg(id, json.object({})))
    else
      self:queue(M.error_msg(id, -32602, "Unknown log level: " .. tostring(params.level)))
    end
    return
  end

  local def = self.methods[method]
  if not def then
    self:queue(M.error_msg(id, -32601, "Method not found: " .. tostring(method)))
    return
  end

  local ctx = self:make_ctx(id, params)
  local entry = {
    id = id,
    key = reqkey(id),
    ctx = ctx,
    on_error = def.on_error,
    cancelled = false,
  }
  entry.co = coroutine.create(function()
    return def.run(params, ctx)
  end)
  self.inflight[entry.key] = entry
  self:step(entry)
end

function Session:feed(line)
  local msg = json.decode(line)
  if type(msg) ~= "table" then
    self:queue(M.error_msg(json.null(), -32700, "Parse error"))
    return self:take_output()
  end
  if msg[1] ~= nil then
    self:queue(M.error_msg(json.null(), -32600, "Batch requests not supported"))
    return self:take_output()
  end
  if msg.method ~= nil then
    self:handle_message(msg)
  elseif msg.id ~= nil then
    self:handle_response(msg)
  end
  return self:take_output()
end

return M
```

- [ ] **Step 5: Run** `scripts/test.sh spec/protocol_spec.lua` — expect PASS (all 13)

- [ ] **Step 6: Run full suite** `scripts/test.sh` — all PASS

- [ ] **Step 7: Commit**

```bash
git add src/rocksmcp/protocol.lua spec/helper.lua spec/protocol_spec.lua
git commit -m "feat: protocol engine lifecycle, framing, errors"
```

---

### Task 5: Protocol engine — coroutine dispatch, client requests, cancellation

**Files:**
- Test: `spec/engine_async_spec.lua` (protocol.lua already contains the implementation from Task 4 — this task VERIFIES the async machinery with dedicated tests and fixes anything the tests expose)

- [ ] **Step 1: Write failing/verifying tests `spec/engine_async_spec.lua`**

```lua
local protocol = require("rocksmcp.protocol")
local json = require("rocksmcp.json")
local H = require("spec.helper")

local function session_with(run, on_error)
  local s = protocol.new({
    info = { name = "t", version = "0" },
    capabilities = function() return json.object({}) end,
    methods = { ["test/run"] = { run = run, on_error = on_error } },
  })
  -- client declares sampling+roots capability so gated calls pass
  H.rpc(s, {
    jsonrpc = "2.0", id = 1, method = "initialize",
    params = {
      protocolVersion = "2025-06-18",
      capabilities = { sampling = json.object({}), roots = json.object({}) },
      clientInfo = { name = "c", version = "0" },
    },
  })
  return s
end

describe("engine async", function()
  it("runs a sync handler to completion", function()
    local s = session_with(function(params) return { ok = true, got = params.x } end)
    local r = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "test/run", params = { x = 7 } })
    assert.equal(7, r[1].result.got)
  end)

  it("maps handler errors to -32603 by default", function()
    local s = session_with(function() error("boom", 0) end)
    local r = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "test/run" })
    assert.equal(-32603, r[1].error.code)
    assert.equal("boom", r[1].error.message)
  end)

  it("respects structured errors with codes", function()
    local s = session_with(function() error({ code = -32002, message = "nope" }, 0) end)
    local r = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "test/run" })
    assert.equal(-32002, r[1].error.code)
  end)

  it("strips lua location prefixes from level-1 errors", function()
    local s = session_with(function() error("plain") end)
    local r = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "test/run" })
    assert.equal("plain", r[1].error.message)
  end)

  it("parks on ctx.sample and resumes with the client response", function()
    local s = session_with(function(params, ctx)
      local res = ctx.sample({ maxTokens = 5 })
      return { answer = res.content.text }
    end)
    local outs = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "test/run" })
    -- no response yet; instead a sampling request went out
    assert.equal(1, #outs)
    assert.equal("sampling/createMessage", outs[1].method)
    local sample_id = outs[1].id
    -- feed the client's response; handler resumes and completes
    local fin = H.rpc(s, { jsonrpc = "2.0", id = sample_id,
      result = { content = { type = "text", text = "hi" } } })
    assert.equal("hi", fin[1].result.answer)
    assert.equal(2, fin[1].id)
  end)

  it("turns client error responses into handler errors", function()
    local s = session_with(function(params, ctx)
      ctx.sample({})
      return { unreachable = true }
    end)
    local outs = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "test/run" })
    local fin = H.rpc(s, { jsonrpc = "2.0", id = outs[1].id,
      error = { code = -1, message = "user said no" } })
    assert.equal(-32603, fin[1].error.code)
    assert.matches("user said no", fin[1].error.message)
  end)

  it("interleaves two in-flight requests", function()
    local s = session_with(function(params, ctx)
      local r = ctx.sample({ tag = params.tag })
      return { tag = params.tag, got = r.v }
    end)
    local o1 = H.rpc(s, { jsonrpc = "2.0", id = 10, method = "test/run", params = { tag = "a" } })
    local o2 = H.rpc(s, { jsonrpc = "2.0", id = 11, method = "test/run", params = { tag = "b" } })
    local s_a, s_b = o1[1].id, o2[1].id
    -- answer b first
    local fb = H.rpc(s, { jsonrpc = "2.0", id = s_b, result = { v = "B" } })
    assert.equal(11, fb[1].id)
    assert.equal("B", fb[1].result.got)
    local fa = H.rpc(s, { jsonrpc = "2.0", id = s_a, result = { v = "A" } })
    assert.equal(10, fa[1].id)
  end)

  it("suppresses responses for cancelled requests", function()
    local s = session_with(function(params, ctx)
      ctx.sample({})
      return { late = true }
    end)
    local outs = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "test/run" })
    H.rpc(s, { jsonrpc = "2.0", method = "notifications/cancelled",
      params = { requestId = 2 } })
    local fin = H.rpc(s, { jsonrpc = "2.0", id = outs[1].id, result = { v = 1 } })
    assert.same({}, fin) -- no response emitted
  end)

  it("exposes cancellation to handlers via ctx.cancelled", function()
    local seen
    local s = session_with(function(params, ctx)
      ctx.sample({})
      seen = ctx.cancelled()
      return { seen = seen }
    end)
    local outs = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "test/run" })
    H.rpc(s, { jsonrpc = "2.0", method = "notifications/cancelled",
      params = { requestId = 2 } })
    H.rpc(s, { jsonrpc = "2.0", id = outs[1].id, result = {} })
    assert.is_true(seen)
  end)

  it("emits progress only when the request carried a token", function()
    local s = session_with(function(params, ctx)
      ctx.progress(0.5, 1, "half")
      return { ok = true }
    end)
    local with = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "test/run",
      params = { _meta = { progressToken = "tok" } } })
    assert.equal("notifications/progress", with[1].method)
    assert.equal("tok", with[1].params.progressToken)
    assert.equal(0.5, with[1].params.progress)
    assert.is_table(with[2].result)
    local without = H.rpc(s, { jsonrpc = "2.0", id = 3, method = "test/run" })
    assert.equal(1, #without)
    assert.is_table(without[1].result)
  end)

  it("filters log notifications below the set level", function()
    local s = session_with(function(params, ctx)
      ctx.log("debug", "noisy")
      ctx.log("error", "loud")
      return { ok = true }
    end)
    H.rpc(s, { jsonrpc = "2.0", id = 5, method = "logging/setLevel",
      params = { level = "warning" } })
    local outs = H.rpc(s, { jsonrpc = "2.0", id = 6, method = "test/run" })
    assert.equal(2, #outs) -- one log (error), one response
    assert.equal("notifications/message", outs[1].method)
    assert.equal("error", outs[1].params.level)
  end)

  it("rejects gated calls when the client lacks the capability", function()
    local s = protocol.new({
      info = { name = "t", version = "0" },
      capabilities = function() return json.object({}) end,
      methods = { ["test/run"] = { run = function(params, ctx) return ctx.elicit({}) end } },
    })
    H.init(s) -- helper declares NO capabilities
    local r = H.rpc(s, { jsonrpc = "2.0", id = 2, method = "test/run" })
    assert.equal(-32603, r[1].error.code)
    assert.matches("does not support elicitation", r[1].error.message)
  end)

  it("rejects client_request from outside a handler", function()
    local s = session_with(function() return {} end)
    assert.error_matches(function()
      s:client_request("roots/list", nil)
    end, "only allowed inside")
  end)
end)
```

- [ ] **Step 2: Run** `scripts/test.sh spec/engine_async_spec.lua`

Expected: mostly PASS since Task 4 shipped the machinery. Any failure here is a bug in protocol.lua — debug and fix in place (do not weaken tests). Likely all 13 pass.

- [ ] **Step 3: Run full suite** `scripts/test.sh` — all PASS

- [ ] **Step 4: Commit**

```bash
git add spec/engine_async_spec.lua src/rocksmcp/protocol.lua
git commit -m "test: async engine coverage — sampling, interleaving, cancellation, progress, logging"
```

---

### Task 6: Server facade + tools

**Files:**
- Create: `src/rocksmcp/server.lua`, `src/rocksmcp/init.lua`
- Test: `spec/tools_spec.lua`

- [ ] **Step 1: Write failing tests `spec/tools_spec.lua`**

```lua
local mcp = require("rocksmcp")
local json = require("rocksmcp.json")
local H = require("spec.helper")

local function demo_server()
  local srv = mcp.server{ name = "demo", version = "1.0.0" }
  srv:tool{
    name = "greet", description = "Say hello",
    input = mcp.schema.obj({ who = mcp.schema.str("Name") }, { "who" }),
    handler = function(args) return { text = "hello " .. args.who } end,
  }
  srv:tool{
    name = "shout", description = "Return a string",
    input = mcp.schema.obj({}, {}),
    handler = function() return "AAH" end,
  }
  srv:tool{
    name = "boom", description = "Fails",
    input = mcp.schema.obj({}, {}),
    handler = function() error("kaboom", 0) end,
  }
  return srv
end

describe("tools", function()
  it("advertises tools capability with listChanged", function()
    local srv = demo_server()
    local res = H.init(srv:engine())
    assert.is_true(res.capabilities.tools.listChanged)
  end)

  it("lists tools in registration order with schemas", function()
    local srv = demo_server()
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/list" })
    local tools = r[1].result.tools
    assert.equal(3, #tools)
    assert.equal("greet", tools[1].name)
    assert.same({ "who" }, tools[1].inputSchema.required)
    assert.is_nil(r[1].result.nextCursor)
  end)

  it("paginates past 50 tools", function()
    local srv = mcp.server{ name = "many", version = "0" }
    for i = 1, 60 do
      srv:tool{ name = "t" .. i, description = "d",
        input = mcp.schema.obj({}, {}), handler = function() return "x" end }
    end
    local e = srv:engine()
    H.init(e)
    local p1 = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/list" })[1].result
    assert.equal(50, #p1.tools)
    assert.is_string(p1.nextCursor)
    local p2 = H.rpc(e, { jsonrpc = "2.0", id = 3, method = "tools/list",
      params = { cursor = p1.nextCursor } })[1].result
    assert.equal(10, #p2.tools)
    assert.is_nil(p2.nextCursor)
    assert.equal("t51", p2.tools[1].name)
  end)

  it("rejects invalid cursors", function()
    local srv = demo_server()
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/list",
      params = { cursor = "garbage" } })
    assert.equal(-32602, r[1].error.code)
  end)

  it("calls a tool: table result becomes JSON text content", function()
    local srv = demo_server()
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/call",
      params = { name = "greet", arguments = { who = "Lua" } } })
    local content = r[1].result.content
    assert.equal("text", content[1].type)
    assert.same({ text = "hello Lua" }, json.decode(content[1].text))
  end)

  it("calls a tool: string result used as-is", function()
    local srv = demo_server()
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/call",
      params = { name = "shout", arguments = json.object({}) } })
    assert.equal("AAH", r[1].result.content[1].text)
  end)

  it("passes pre-shaped results through", function()
    local srv = mcp.server{ name = "s", version = "0" }
    srv:tool{ name = "raw", description = "d", input = mcp.schema.obj({}, {}),
      handler = function()
        return { content = json.array({ { type = "text", text = "raw" } }) }
      end }
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/call",
      params = { name = "raw" } })
    assert.equal("raw", r[1].result.content[1].text)
  end)

  it("maps handler errors to isError results, not protocol errors", function()
    local srv = demo_server()
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/call",
      params = { name = "boom" } })
    assert.is_true(r[1].result.isError)
    assert.equal("kaboom", r[1].result.content[1].text)
  end)

  it("errors -32602 for unknown tools", function()
    local srv = demo_server()
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/call",
      params = { name = "nope" } })
    assert.equal(-32602, r[1].error.code)
  end)

  it("emits tools list_changed notification", function()
    local srv = demo_server()
    local e = srv:engine()
    H.init(e)
    srv:tools_changed()
    local out = e:take_output()
    assert.equal("notifications/tools/list_changed", json.decode(out[1]).method)
  end)

  it("rejects duplicate tool names", function()
    local srv = demo_server()
    assert.error_matches(function()
      srv:tool{ name = "greet", description = "again",
        input = mcp.schema.obj({}, {}), handler = function() end }
    end, "already registered")
  end)
end)
```

- [ ] **Step 2: Run** `scripts/test.sh spec/tools_spec.lua` — expect FAIL `module 'rocksmcp' not found`

- [ ] **Step 3: Write `src/rocksmcp/server.lua`**

```lua
local protocol = require("rocksmcp.protocol")
local json = require("rocksmcp.json")

local M = {}

local PAGE = 50

-- shared cursor pagination over a materialized list
function M.paginate(list, cursor)
  local start = 1
  if cursor ~= nil then
    start = tonumber(cursor)
    if start == nil or start < 1 or start % 1 ~= 0 then
      error({ code = -32602, message = "Invalid cursor" }, 0)
    end
  end
  local page = {}
  for i = start, math.min(start + PAGE - 1, #list) do
    page[#page + 1] = list[i]
  end
  local next_cursor
  if start + PAGE <= #list then
    next_cursor = tostring(start + PAGE)
  end
  return page, next_cursor
end

function M.capabilities(registry)
  local caps = { logging = json.object({}) }
  if next(registry.tools) ~= nil then
    caps.tools = { listChanged = true }
  end
  if next(registry.resources) ~= nil or #registry.template_order > 0 then
    caps.resources = { subscribe = true, listChanged = true }
  end
  if next(registry.prompts) ~= nil then
    caps.prompts = { listChanged = true }
  end
  if registry.completion then
    caps.completions = json.object({})
  end
  return caps
end

local function shape_tool_result(res)
  if type(res) == "table" and res.content ~= nil then
    return res
  end
  local text
  if type(res) == "string" then
    text = res
  elseif res == nil then
    text = json.encode(json.object({}))
  else
    text = json.encode(res)
  end
  return { content = json.array({ { type = "text", text = text } }) }
end

local function tool_error(id, err)
  if type(err) == "table" and err.code then
    return protocol.error_msg(id, err.code, err.message or "error", err.data)
  end
  return protocol.result_msg(id, {
    content = json.array({ { type = "text", text = tostring(err) } }),
    isError = true,
  })
end

function M.build_methods(registry)
  local methods = {}

  methods["tools/list"] = {
    run = function(params)
      local descs = {}
      for _, name in ipairs(registry.tool_order) do
        local t = registry.tools[name]
        descs[#descs + 1] = {
          name = t.name, description = t.description, inputSchema = t.input,
        }
      end
      local page, nxt = M.paginate(descs, params.cursor)
      return { tools = json.array(page), nextCursor = nxt }
    end,
  }

  methods["tools/call"] = {
    run = function(params, ctx)
      local tool = registry.tools[params.name]
      if not tool then
        error({ code = -32602, message = "Unknown tool: " .. tostring(params.name) }, 0)
      end
      local args = params.arguments
      if args == json.null() or args == nil then args = {} end
      return shape_tool_result(tool.handler(args, ctx))
    end,
    on_error = tool_error,
  }

  return methods
end

return M
```

- [ ] **Step 4: Write `src/rocksmcp/init.lua`**

```lua
local protocol = require("rocksmcp.protocol")
local server = require("rocksmcp.server")
local json = require("rocksmcp.json")

local mcp = {}

mcp.schema = require("rocksmcp.schema")
mcp.json = json

function mcp.use_json(codec)
  return json.use(codec)
end

-- content helpers
function mcp.text(s)
  return { type = "text", text = s }
end

function mcp.user_text(s)
  return { role = "user", content = mcp.text(s) }
end

function mcp.assistant_text(s)
  return { role = "assistant", content = mcp.text(s) }
end

local Server = {}
Server.__index = Server

function mcp.server(opts)
  assert(type(opts) == "table" and opts.name and opts.version,
    "mcp.server requires { name = ..., version = ... }")
  return setmetatable({
    info = { name = opts.name, version = opts.version },
    instructions = opts.instructions,
    registry = {
      tools = {}, tool_order = {},
      resources = {}, resource_order = {},
      templates = {}, template_order = {},
      prompts = {}, prompt_order = {},
      completion = nil,
      subscriptions = {},
    },
    _engine = nil,
  }, Server)
end

function Server:tool(def)
  assert(type(def) == "table" and def.name and def.handler and def.input,
    "tool requires name, input, handler")
  assert(not self.registry.tools[def.name],
    "tool already registered: " .. tostring(def.name))
  self.registry.tools[def.name] = def
  local order = self.registry.tool_order
  order[#order + 1] = def.name
  return self
end

function Server:completion(fn)
  assert(type(fn) == "function", "completion requires a function")
  self.registry.completion = fn
  return self
end

function Server:engine()
  if not self._engine then
    local registry = self.registry
    self._engine = protocol.new({
      info = self.info,
      instructions = self.instructions,
      capabilities = function() return server.capabilities(registry) end,
      methods = server.build_methods(registry),
    })
  end
  return self._engine
end

function Server:notify(method, params)
  self:engine():notify(method, params)
end

function Server:tools_changed()
  self:notify("notifications/tools/list_changed", nil)
end

function Server:resources_changed()
  self:notify("notifications/resources/list_changed", nil)
end

function Server:prompts_changed()
  self:notify("notifications/prompts/list_changed", nil)
end

function Server:resource_updated(uri)
  if self.registry.subscriptions[uri] then
    self:notify("notifications/resources/updated", { uri = uri })
  end
end

function Server:run()
  require("rocksmcp.transport.stdio").run(self:engine())
end

return mcp
```

(`Server:resource`/`:resource_template`/`:prompt` arrive in Tasks 7–8; `transport.stdio` in Task 9. `Server:run` referencing it now is fine — nothing calls it in tests yet.)

- [ ] **Step 5: Run** `scripts/test.sh spec/tools_spec.lua` — expect PASS (all 11)

- [ ] **Step 6: Run full suite** — all PASS

- [ ] **Step 7: Commit**

```bash
git add src/rocksmcp/server.lua src/rocksmcp/init.lua spec/tools_spec.lua
git commit -m "feat: server facade with tools, pagination, capabilities"
```

---

### Task 7: Resources — static, templates, subscriptions

**Files:**
- Modify: `src/rocksmcp/server.lua` (add resource methods to build_methods), `src/rocksmcp/init.lua` (add :resource, :resource_template)
- Test: `spec/resources_spec.lua`

- [ ] **Step 1: Write failing tests `spec/resources_spec.lua`**

```lua
local mcp = require("rocksmcp")
local json = require("rocksmcp.json")
local H = require("spec.helper")

local function file_server()
  local srv = mcp.server{ name = "files", version = "0" }
  srv:resource{ uri = "demo://readme", name = "README", mime = "text/plain",
    description = "The readme",
    read = function() return "hello docs" end }
  srv:resource{ uri = "demo://logo", name = "Logo", mime = "image/png",
    read = function() return { blob = "aGk=" } end }
  srv:resource_template{ uri_template = "demo://files/{path}", name = "Files",
    mime = "text/plain",
    read = function(uri, ctx, vars) return "file:" .. vars.path end }
  return srv
end

describe("resources", function()
  it("advertises resources capability with subscribe", function()
    local res = H.init(file_server():engine())
    assert.is_true(res.capabilities.resources.subscribe)
    assert.is_true(res.capabilities.resources.listChanged)
  end)

  it("lists static resources", function()
    local e = file_server():engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "resources/list" })
    local list = r[1].result.resources
    assert.equal(2, #list)
    assert.equal("demo://readme", list[1].uri)
    assert.equal("text/plain", list[1].mimeType)
    assert.equal("The readme", list[1].description)
  end)

  it("lists templates", function()
    local e = file_server():engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "resources/templates/list" })
    local list = r[1].result.resourceTemplates
    assert.equal(1, #list)
    assert.equal("demo://files/{path}", list[1].uriTemplate)
  end)

  it("reads a static text resource", function()
    local e = file_server():engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "resources/read",
      params = { uri = "demo://readme" } })
    local c = r[1].result.contents[1]
    assert.equal("demo://readme", c.uri)
    assert.equal("text/plain", c.mimeType)
    assert.equal("hello docs", c.text)
  end)

  it("reads a blob resource", function()
    local e = file_server():engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "resources/read",
      params = { uri = "demo://logo" } })
    local c = r[1].result.contents[1]
    assert.equal("aGk=", c.blob)
    assert.equal("image/png", c.mimeType)
  end)

  it("reads through a template with captured vars", function()
    local e = file_server():engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "resources/read",
      params = { uri = "demo://files/notes/today.md" } })
    assert.equal("file:notes/today.md", r[1].result.contents[1].text)
  end)

  it("errors -32002 for unknown uris", function()
    local e = file_server():engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "resources/read",
      params = { uri = "demo://missing" } })
    assert.equal(-32002, r[1].error.code)
  end)

  it("subscribes and receives updates only for subscribed uris", function()
    local srv = file_server()
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "resources/subscribe",
      params = { uri = "demo://readme" } })
    assert.is_table(r[1].result)
    srv:resource_updated("demo://readme")
    srv:resource_updated("demo://logo") -- not subscribed
    local out = e:take_output()
    assert.equal(1, #out)
    local note = json.decode(out[1])
    assert.equal("notifications/resources/updated", note.method)
    assert.equal("demo://readme", note.params.uri)
  end)

  it("unsubscribes", function()
    local srv = file_server()
    local e = srv:engine()
    H.init(e)
    H.rpc(e, { jsonrpc = "2.0", id = 2, method = "resources/subscribe",
      params = { uri = "demo://readme" } })
    H.rpc(e, { jsonrpc = "2.0", id = 3, method = "resources/unsubscribe",
      params = { uri = "demo://readme" } })
    srv:resource_updated("demo://readme")
    assert.same({}, e:take_output())
  end)

  it("escapes pattern magic in templates", function()
    local srv = mcp.server{ name = "s", version = "0" }
    srv:resource_template{ uri_template = "x+y://a.b/{n}", name = "T",
      read = function(uri, ctx, vars) return vars.n end }
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "resources/read",
      params = { uri = "x+y://a.b/42" } })
    assert.equal("42", r[1].result.contents[1].text)
    local miss = H.rpc(e, { jsonrpc = "2.0", id = 3, method = "resources/read",
      params = { uri = "xxy://aXb/42" } })
    assert.equal(-32002, miss[1].error.code)
  end)
end)
```

- [ ] **Step 2: Run** `scripts/test.sh spec/resources_spec.lua` — expect FAIL (`resource` method nil)

- [ ] **Step 3: Add to `src/rocksmcp/init.lua`** (after `Server:tool`)

```lua
function Server:resource(def)
  assert(type(def) == "table" and def.uri and def.name and def.read,
    "resource requires uri, name, read")
  assert(not self.registry.resources[def.uri],
    "resource already registered: " .. tostring(def.uri))
  self.registry.resources[def.uri] = def
  local order = self.registry.resource_order
  order[#order + 1] = def.uri
  return self
end

function Server:resource_template(def)
  assert(type(def) == "table" and def.uri_template and def.name and def.read,
    "resource_template requires uri_template, name, read")
  local server_mod = require("rocksmcp.server")
  def.pattern, def.var_names = server_mod.compile_template(def.uri_template)
  local order = self.registry.template_order
  order[#order + 1] = def
  return self
end
```

- [ ] **Step 4: Add to `src/rocksmcp/server.lua`**

Add below `M.paginate`:

```lua
-- compile "scheme://x/{a}/{b}" into an anchored Lua pattern + capture names
function M.compile_template(tmpl)
  local names = {}
  for n in tmpl:gmatch("{(%w+)}") do
    names[#names + 1] = n
  end
  local escaped = tmpl:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
  local pattern = "^" .. escaped:gsub("{%w+}", "(.-)") .. "$"
  return pattern, names
end

local function match_template(def, uri)
  local caps = { uri:match(def.pattern) }
  if caps[1] == nil then return nil end
  local vars = {}
  for i, n in ipairs(def.var_names) do
    vars[n] = caps[i]
  end
  return vars
end

local function shape_contents(uri, mime, res)
  if type(res) == "table" then
    if res.contents ~= nil then return res end
    if res.text ~= nil or res.blob ~= nil then
      res.uri = res.uri or uri
      res.mimeType = res.mimeType or mime
      return { contents = json.array({ res }) }
    end
    error("resource read handler returned an unrecognized table", 0)
  end
  return { contents = json.array({ { uri = uri, mimeType = mime, text = tostring(res) } }) }
end
```

Add inside `M.build_methods` (before `return methods`):

```lua
  methods["resources/list"] = {
    run = function(params)
      local descs = {}
      for _, uri in ipairs(registry.resource_order) do
        local r = registry.resources[uri]
        descs[#descs + 1] = {
          uri = r.uri, name = r.name, description = r.description, mimeType = r.mime,
        }
      end
      local page, nxt = M.paginate(descs, params.cursor)
      return { resources = json.array(page), nextCursor = nxt }
    end,
  }

  methods["resources/templates/list"] = {
    run = function(params)
      local descs = {}
      for _, t in ipairs(registry.template_order) do
        descs[#descs + 1] = {
          uriTemplate = t.uri_template, name = t.name,
          description = t.description, mimeType = t.mime,
        }
      end
      local page, nxt = M.paginate(descs, params.cursor)
      return { resourceTemplates = json.array(page), nextCursor = nxt }
    end,
  }

  methods["resources/read"] = {
    run = function(params, ctx)
      local uri = params.uri
      if type(uri) ~= "string" then
        error({ code = -32602, message = "uri is required" }, 0)
      end
      local res = registry.resources[uri]
      if res then
        return shape_contents(uri, res.mime, res.read(uri, ctx))
      end
      for _, t in ipairs(registry.template_order) do
        local vars = match_template(t, uri)
        if vars then
          return shape_contents(uri, t.mime, t.read(uri, ctx, vars))
        end
      end
      error({ code = -32002, message = "Resource not found: " .. uri }, 0)
    end,
  }

  local function known_uri(uri)
    if registry.resources[uri] then return true end
    for _, t in ipairs(registry.template_order) do
      if match_template(t, uri) then return true end
    end
    return false
  end

  methods["resources/subscribe"] = {
    run = function(params)
      local uri = params.uri
      if type(uri) ~= "string" or not known_uri(uri) then
        error({ code = -32002, message = "Resource not found: " .. tostring(uri) }, 0)
      end
      registry.subscriptions[uri] = true
      return json.object({})
    end,
  }

  methods["resources/unsubscribe"] = {
    run = function(params)
      registry.subscriptions[params.uri] = nil
      return json.object({})
    end,
  }
```

- [ ] **Step 5: Run** `scripts/test.sh spec/resources_spec.lua` — expect PASS (all 10)

- [ ] **Step 6: Run full suite** — all PASS

- [ ] **Step 7: Commit**

```bash
git add src/rocksmcp/server.lua src/rocksmcp/init.lua spec/resources_spec.lua
git commit -m "feat: resources — static, uri templates, subscriptions"
```

---

### Task 8: Prompts + completion

**Files:**
- Modify: `src/rocksmcp/server.lua`, `src/rocksmcp/init.lua`
- Test: `spec/prompts_spec.lua`

- [ ] **Step 1: Write failing tests `spec/prompts_spec.lua`**

```lua
local mcp = require("rocksmcp")
local json = require("rocksmcp.json")
local H = require("spec.helper")

local function prompt_server()
  local srv = mcp.server{ name = "p", version = "0" }
  srv:prompt{
    name = "review", description = "Code review",
    args = {
      { name = "lang", description = "Language", required = true },
      { name = "style", required = false },
    },
    get = function(args)
      return { messages = json.array({ mcp.user_text("Review some " .. args.lang) }) }
    end,
  }
  srv:completion(function(ref, argument)
    if argument and argument.name == "lang" then
      return { "lua", "luajit" }
    end
    return {}
  end)
  return srv
end

describe("prompts", function()
  it("advertises prompts and completions capabilities", function()
    local res = H.init(prompt_server():engine())
    assert.is_true(res.capabilities.prompts.listChanged)
    assert.is_table(res.capabilities.completions)
  end)

  it("lists prompts with argument descriptors", function()
    local e = prompt_server():engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "prompts/list" })
    local p = r[1].result.prompts[1]
    assert.equal("review", p.name)
    assert.equal("lang", p.arguments[1].name)
    assert.is_true(p.arguments[1].required)
  end)

  it("gets a prompt", function()
    local e = prompt_server():engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "prompts/get",
      params = { name = "review", arguments = { lang = "lua" } } })
    local m = r[1].result.messages[1]
    assert.equal("user", m.role)
    assert.equal("Review some lua", m.content.text)
  end)

  it("rejects missing required arguments", function()
    local e = prompt_server():engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "prompts/get",
      params = { name = "review", arguments = json.object({}) } })
    assert.equal(-32602, r[1].error.code)
    assert.matches("lang", r[1].error.message)
  end)

  it("errors on unknown prompt", function()
    local e = prompt_server():engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "prompts/get",
      params = { name = "nope" } })
    assert.equal(-32602, r[1].error.code)
  end)

  it("completes argument values", function()
    local e = prompt_server():engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "completion/complete",
      params = { ref = { type = "ref/prompt", name = "review" },
                 argument = { name = "lang", value = "l" } } })
    assert.same({ "lua", "luajit" }, r[1].result.completion.values)
  end)

  it("caps completion values at 100", function()
    local srv = mcp.server{ name = "s", version = "0" }
    srv:prompt{ name = "p", get = function() return { messages = json.array({}) } end }
    srv:completion(function()
      local v = {}
      for i = 1, 150 do v[i] = "v" .. i end
      return v
    end)
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "completion/complete",
      params = { ref = { type = "ref/prompt", name = "p" },
                 argument = { name = "x", value = "" } } })
    assert.equal(100, #r[1].result.completion.values)
  end)

  it("errors when no completion handler is registered", function()
    local srv = mcp.server{ name = "s", version = "0" }
    srv:prompt{ name = "p", get = function() return { messages = json.array({}) } end }
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "completion/complete",
      params = { ref = { type = "ref/prompt", name = "p" },
                 argument = { name = "x", value = "" } } })
    assert.equal(-32601, r[1].error.code)
  end)
end)
```

- [ ] **Step 2: Run** `scripts/test.sh spec/prompts_spec.lua` — expect FAIL (`prompt` method nil)

- [ ] **Step 3: Add to `src/rocksmcp/init.lua`** (after `Server:resource_template`)

```lua
function Server:prompt(def)
  assert(type(def) == "table" and def.name and def.get,
    "prompt requires name, get")
  assert(not self.registry.prompts[def.name],
    "prompt already registered: " .. tostring(def.name))
  self.registry.prompts[def.name] = def
  local order = self.registry.prompt_order
  order[#order + 1] = def.name
  return self
end
```

- [ ] **Step 4: Add inside `M.build_methods` in `src/rocksmcp/server.lua`** (before `return methods`)

```lua
  methods["prompts/list"] = {
    run = function(params)
      local descs = {}
      for _, name in ipairs(registry.prompt_order) do
        local p = registry.prompts[name]
        local args
        if p.args and #p.args > 0 then
          args = {}
          for i, a in ipairs(p.args) do
            args[i] = {
              name = a.name, description = a.description,
              required = a.required or nil,
            }
          end
          args = json.array(args)
        end
        descs[#descs + 1] = {
          name = p.name, description = p.description, arguments = args,
        }
      end
      local page, nxt = M.paginate(descs, params.cursor)
      return { prompts = json.array(page), nextCursor = nxt }
    end,
  }

  methods["prompts/get"] = {
    run = function(params, ctx)
      local p = registry.prompts[params.name]
      if not p then
        error({ code = -32602, message = "Unknown prompt: " .. tostring(params.name) }, 0)
      end
      local args = params.arguments
      if args == json.null() or args == nil then args = {} end
      for _, a in ipairs(p.args or {}) do
        if a.required and args[a.name] == nil then
          error({ code = -32602, message = "Missing required argument: " .. a.name }, 0)
        end
      end
      local res = p.get(args, ctx)
      if type(res) ~= "table" or res.messages == nil then
        error("prompt get handler must return { messages = ... }", 0)
      end
      res.description = res.description or p.description
      return res
    end,
  }

  methods["completion/complete"] = {
    run = function(params, ctx)
      if not registry.completion then
        error({ code = -32601, message = "Completions not supported" }, 0)
      end
      local res = registry.completion(params.ref, params.argument, ctx)
      local values, total, has_more
      if type(res) == "table" and res.values ~= nil then
        values, total, has_more = res.values, res.total, res.hasMore
      else
        values = res or {}
      end
      local capped = {}
      for i = 1, math.min(#values, 100) do
        capped[i] = values[i]
      end
      if has_more == nil and #values > 100 then has_more = true end
      return { completion = { values = json.array(capped), total = total, hasMore = has_more } }
    end,
  }
```

- [ ] **Step 5: Run** `scripts/test.sh spec/prompts_spec.lua` — expect PASS (all 8)

- [ ] **Step 6: Run full suite** — all PASS

- [ ] **Step 7: Commit**

```bash
git add src/rocksmcp/server.lua src/rocksmcp/init.lua spec/prompts_spec.lua
git commit -m "feat: prompts and completion"
```

---

### Task 9: Stdio transport + examples

**Files:**
- Create: `src/rocksmcp/transport/stdio.lua`, `examples/echo.lua`, `examples/fileserver.lua`
- Test: `spec/integration_spec.lua`

- [ ] **Step 1: Write failing test `spec/integration_spec.lua`**

```lua
local json = require("rocksmcp.json")
local H = require("spec.helper")

describe("integration", function()
  it("echo example builds a working server", function()
    local srv = dofile("examples/echo.lua")
    local e = srv:engine()
    local init = H.init(e)
    assert.equal("echo", init.serverInfo.name)
    assert.is_true(init.capabilities.tools.listChanged)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "tools/call",
      params = { name = "echo", arguments = { text = "bounce" } } })
    assert.equal("bounce", r[1].result.content[1].text)
  end)

  it("fileserver example serves resources", function()
    local srv = dofile("examples/fileserver.lua")
    local e = srv:engine()
    H.init(e)
    local r = H.rpc(e, { jsonrpc = "2.0", id = 2, method = "resources/read",
      params = { uri = "example://greeting" } })
    assert.matches("Hello", r[1].result.contents[1].text)
  end)
end)
```

Note: examples must `return srv` WITHOUT calling `srv:run()` when loaded under busted. Convention: examples call `srv:run()` only when executed directly (`arg ~= nil and arg[0] and arg[0]:match("examples")`), and always `return srv`.

- [ ] **Step 2: Run** `scripts/test.sh spec/integration_spec.lua` — expect FAIL (no examples)

- [ ] **Step 3: Write `src/rocksmcp/transport/stdio.lua`**

```lua
-- Newline-delimited JSON-RPC over stdio. Blocking single-threaded loop;
-- concurrency comes from the engine parking coroutines, not threads.
local M = {}

function M.run(engine)
  local stdout = io.stdout
  local function drain(lines)
    for i = 1, #lines do
      stdout:write(lines[i], "\n")
    end
    stdout:flush()
  end
  drain(engine:take_output()) -- anything queued before the loop
  for line in io.stdin:lines() do
    if line ~= "" then
      drain(engine:feed(line))
    end
  end
end

return M
```

- [ ] **Step 4: Write `examples/echo.lua`**

```lua
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
```

- [ ] **Step 5: Write `examples/fileserver.lua`**

```lua
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
```

- [ ] **Step 6: Run** `scripts/test.sh spec/integration_spec.lua` — expect PASS

- [ ] **Step 7: Manual stdio smoke test**

```bash
cd /home/user/projects/rocksmcp && printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}' \
  | eval "$(luarocks --lua-version 5.4 --tree .rocks path)" lua5.4 examples/echo.lua
```

Note: `eval` inside a pipeline doesn't work like that — run as two commands instead:

```bash
cd /home/user/projects/rocksmcp
eval "$(luarocks --lua-version 5.4 --tree .rocks path)"
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}' \
  | lua5.4 examples/echo.lua
```

Expected: two JSON lines — initialize result with `"name":"echo"`, then a result whose content text is `hi`. No stack traces.

- [ ] **Step 8: Run full suite** — all PASS

- [ ] **Step 9: Commit**

```bash
git add src/rocksmcp/transport/stdio.lua examples spec/integration_spec.lua
git commit -m "feat: stdio transport and runnable examples"
```

---

### Task 10: LuaJIT compat smoke, README, LICENSE

**Files:**
- Create: `scripts/smoke.lua`, `scripts/compat.sh`, `README.md`, `LICENSE`

- [ ] **Step 1: Write `scripts/smoke.lua`**

```lua
-- End-to-end smoke for alternative interpreters (LuaJIT = Lua 5.1 semantics).
-- Usage: luajit scripts/smoke.lua   (from repo root)
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
```

- [ ] **Step 2: Write `scripts/compat.sh`** then `chmod +x scripts/compat.sh`

```sh
#!/bin/sh
# Run the smoke script under every available alternative interpreter.
set -e
cd "$(dirname "$0")/.."
found=0
for interp in luajit lua5.1 lua5.3 lua5.4; do
  if command -v "$interp" >/dev/null 2>&1; then
    found=1
    echo "--- $interp"
    "$interp" scripts/smoke.lua
  fi
done
[ "$found" = "1" ] || { echo "no interpreters found"; exit 1; }
```

- [ ] **Step 3: Run** `scripts/compat.sh`

Expected output includes `--- luajit` then `Lua 5.1 (LuaJIT ...): smoke OK`, plus lua5.3/lua5.4 lines, all `smoke OK`. Any failure under luajit = a 5.1 compat bug in src/ — fix it (typical culprits: pcall-across-yield, `table.unpack`, goto).

- [ ] **Step 4: Write `LICENSE`** — MIT, same text as `/home/user/projects/ankimcp/LICENSE` (copy it: `cp /home/user/projects/ankimcp/LICENSE LICENSE`).

- [ ] **Step 5: Write `README.md`**

````markdown
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
| `srv:tool{name, description, input, handler}` | register a tool; handler `(args, ctx) → string \| table \| {content=...}` |
| `srv:resource{uri, name, mime?, description?, read}` | static resource; read `(uri, ctx) → string \| {text=} \| {blob=}` |
| `srv:resource_template{uri_template, name, mime?, read}` | `{var}` templates; read gets `(uri, ctx, vars)` |
| `srv:prompt{name, description?, args?, get}` | prompt; get `(args, ctx) → {messages=...}` |
| `srv:completion(fn)` | argument completion; `fn(ref, argument, ctx) → values` |
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

## Development

```sh
luarocks --lua-version 5.4 --tree .rocks install dkjson
luarocks --lua-version 5.4 --tree .rocks install busted
scripts/test.sh        # busted suite
scripts/compat.sh      # smoke under luajit / other interpreters
```

Examples: `examples/echo.lua`, `examples/fileserver.lua`.

MIT.
````

- [ ] **Step 6: Run full suite + compat one last time**

Run: `scripts/test.sh && scripts/compat.sh`
Expected: all tests pass, all interpreters `smoke OK`.

- [ ] **Step 7: Commit**

```bash
git add scripts/smoke.lua scripts/compat.sh README.md LICENSE
git commit -m "feat: compat smoke, README, LICENSE"
```

---

### Task 11: Final verification (manual)

- [ ] **Step 1:** `scripts/test.sh` — expect ~70 tests, 0 failures (1 pending for cjson)
- [ ] **Step 2:** `scripts/compat.sh` — luajit + lua5.3 + lua5.4 all `smoke OK`
- [ ] **Step 3:** stdio smoke from Task 9 Step 7 against `examples/echo.lua` — clean JSON only
- [ ] **Step 4:** `luarocks --lua-version 5.4 --tree /tmp/rockstest make` from repo root — rockspec installs cleanly; then `rm -rf /tmp/rockstest`
