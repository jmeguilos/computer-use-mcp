#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /absolute/path/to/computer-use-mcp" >&2
  exit 2
fi

project_root=$1
entry_point="$project_root/packages/mcp/dist/index.js"

if [ ! -f "$entry_point" ]; then
  echo "missing built MCP entry point: $entry_point" >&2
  echo "run npm ci && npm run build first" >&2
  exit 1
fi

exec npx --yes @modelcontextprotocol/inspector@2.4.0 node "$entry_point"
