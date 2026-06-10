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
