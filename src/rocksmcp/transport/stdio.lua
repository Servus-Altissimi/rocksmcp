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
