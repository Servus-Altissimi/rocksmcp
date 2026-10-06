# Notes for agents

Two kinds of agent read this: one writing a server with RocksMCP, and one
changing RocksMCP itself.

## Writing a server with RocksMCP

Read `doc/api.md` first. It is the whole public API on one page. In short:

- Turn on `validate_input = true` and `max_result_bytes` in `mcp.server{}`
  unless there is a reason not to.
- Give every tool a description that says when to call it and what the
  arguments mean. It is the only manual the calling model gets.
- `error("msg", 0)` for expected failures; plain `error("msg")` or a crash
  logs a traceback to stderr. Never `print`: stdout is the protocol.
- Return data tables, or `mcp.result{...}` for a hand-built result.
- Test with `rocksmcp.testing`: `testing.client(srv):call(name, args)`.

## Changing RocksMCP

- Lua 5.1 compatible: no `goto`, no `//`, no `utf8` library, no
  `math.type`, `table.unpack or unpack`. Yields must not cross a `pcall`.
- `scripts/test.sh` runs busted on Lua 5.4; `scripts/compat.sh` runs
  `scripts/smoke.lua` on every interpreter installed. Both must pass.
- A new module needs an entry in the rockspec `build.modules`.
- A public change updates `doc/api.md`, the LuaLS annotations and the README.
