#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /absolute/path/ComputerUseMCPHost.app" >&2
  exit 64
fi

app_path="$1"
plist_path="$app_path/Contents/Info.plist"
host_path="$app_path/Contents/MacOS/ComputerUseMCPHost"
bridge_path="$app_path/Contents/Helpers/ComputerUseMCPBridge"

[[ "$app_path" = /* ]] || { echo "app path must be absolute" >&2; exit 64; }
[[ -f "$plist_path" && -x "$host_path" && -x "$bridge_path" ]] || {
  echo "app bundle is missing its plist, host, or bridge" >&2
  exit 1
}

bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$plist_path")"
minimum_os="$(plutil -extract LSMinimumSystemVersion raw -o - "$plist_path")"
agent_only="$(plutil -extract LSUIElement raw -o - "$plist_path")"
executable="$(plutil -extract CFBundleExecutable raw -o - "$plist_path")"
screen_capture_reason="$(plutil -extract NSScreenCaptureUsageDescription raw -o - "$plist_path")"

[[ "$bundle_id" == "com.jmeguilos.computer-use-mcp.host" ]] || { echo "unexpected bundle id: $bundle_id" >&2; exit 1; }
[[ "$minimum_os" == "14.4" ]] || { echo "unexpected minimum OS: $minimum_os" >&2; exit 1; }
[[ "$agent_only" == "true" ]] || { echo "LSUIElement must be true" >&2; exit 1; }
[[ "$executable" == "ComputerUseMCPHost" ]] || { echo "unexpected executable: $executable" >&2; exit 1; }
[[ -n "$screen_capture_reason" ]] || { echo "NSScreenCaptureUsageDescription must be present" >&2; exit 1; }

echo "Validated ComputerUseMCPHost.app ($bundle_id, macOS $minimum_os+)"
