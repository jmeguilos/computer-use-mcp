#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
package_root="$(cd "$script_dir/.." && pwd -P)"
output_app="$package_root/build/ComputerUseMCPHost.app"
signing_identity=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 && "$2" = /* ]] || { echo "--output requires an absolute .app path" >&2; exit 64; }
      output_app="$2"
      shift 2
      ;;
    --codesign-identity)
      [[ $# -ge 2 && -n "$2" ]] || { echo "--codesign-identity requires a value" >&2; exit 64; }
      signing_identity="$2"
      shift 2
      ;;
    --adhoc-sign)
      signing_identity="-"
      shift
      ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

[[ "$output_app" == *.app ]] || { echo "output must end in .app" >&2; exit 64; }

if [[ -L "$output_app" ]]; then
  echo "refusing to replace a symlinked app output: $output_app" >&2
  exit 1
fi
if [[ -e "$output_app" ]]; then
  existing_plist="$output_app/Contents/Info.plist"
  if [[ ! -d "$output_app" || -L "$existing_plist" || ! -f "$existing_plist" ]]; then
    echo "refusing to replace an output that is not an inspectable app bundle: $output_app" >&2
    exit 1
  fi
  existing_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$existing_plist" 2>/dev/null || true)"
  if [[ "$existing_bundle_id" != "com.jmeguilos.computer-use-mcp.host" ]]; then
    echo "refusing to replace an app with a different or unreadable bundle identity: $output_app" >&2
    exit 1
  fi
  if [[ "$(stat -f '%u' "$output_app")" != "$(id -u)" ]]; then
    echo "refusing to replace an app bundle not owned by the current user: $output_app" >&2
    exit 1
  fi
fi

swift build --package-path "$package_root" -c release --product ComputerUseMCPHost
swift build --package-path "$package_root" -c release --product ComputerUseMCPBridge
bin_path="$(swift build --package-path "$package_root" -c release --show-bin-path)"

staging_parent="$(mktemp -d "${TMPDIR:-/tmp}/computer-use-mcp-app.XXXXXX")"
trap 'rm -rf "$staging_parent"' EXIT
staging_app="$staging_parent/ComputerUseMCPHost.app"
mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Helpers"
install -m 0755 "$bin_path/ComputerUseMCPHost" "$staging_app/Contents/MacOS/ComputerUseMCPHost"
install -m 0755 "$bin_path/ComputerUseMCPBridge" "$staging_app/Contents/Helpers/ComputerUseMCPBridge"
install -m 0644 "$package_root/Support/Info.plist" "$staging_app/Contents/Info.plist"

if [[ -n "$signing_identity" ]]; then
  codesign --force --sign "$signing_identity" \
    --identifier com.jmeguilos.computer-use-mcp.bridge \
    "$staging_app/Contents/Helpers/ComputerUseMCPBridge"
  codesign --force --sign "$signing_identity" \
    --identifier com.jmeguilos.computer-use-mcp.host \
    "$staging_app"
fi

"$script_dir/validate-app.sh" "$staging_app"
mkdir -p "$(dirname "$output_app")"
if [[ -e "$output_app" ]]; then
  rm -rf "$output_app"
fi
ditto "$staging_app" "$output_app"
"$script_dir/validate-app.sh" "$output_app"
echo "$output_app"
