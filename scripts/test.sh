#!/bin/sh
set -e
cd "$(dirname "$0")/.."
eval "$(luarocks --lua-version 5.4 --tree .rocks path)"
export LUA_PATH="./?.lua;./src/?.lua;./src/?/init.lua;$LUA_PATH"
exec .rocks/bin/busted "$@"
