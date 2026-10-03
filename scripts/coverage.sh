#!/bin/sh
# Run the suite with coverage and fail below the gate (default 99%).
set -e
cd "$(dirname "$0")/.."
if [ -d .rocks ]; then
  eval "$(luarocks --lua-version 5.4 --tree .rocks path)"
  export LUA_PATH="./?.lua;./src/?.lua;./src/?/init.lua;$LUA_PATH"
  BUSTED=.rocks/bin/busted
  LUACOV=.rocks/bin/luacov
else
  export LUA_PATH="./?.lua;./src/?.lua;./src/?/init.lua;${LUA_PATH};;"
  BUSTED=busted
  LUACOV=luacov
fi
GATE="${COVERAGE_GATE:-99}"
rm -f luacov.stats.out luacov.report.out
"$BUSTED" --coverage "$@"
"$LUACOV" src
grep -E "^(File|src/|Total)" luacov.report.out
total=$(awk '/^Total/{gsub("%","",$NF); print $NF}' luacov.report.out)
awk -v t="$total" -v g="$GATE" \
  'BEGIN{ printf "line coverage %.2f%% (gate %s%%)\n", t, g; exit (t+0 < g+0) }'
