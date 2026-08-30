#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
package_root="$(cd "$script_dir/.." && pwd -P)"
fixture_app="$package_root/build/ComputerUseMCPFixture.app"
assemble_only=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --assemble-only)
      assemble_only=true
      shift
      ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

swift build --package-path "$package_root" -c release --product computer-use-mcp-fixture >&2
bin_path="$(swift build --package-path "$package_root" -c release --show-bin-path)"
staging_parent="$(mktemp -d "${TMPDIR:-/tmp}/computer-use-mcp-fixture.XXXXXX")"
trap 'rm -rf "$staging_parent"' EXIT
staging_app="$staging_parent/ComputerUseMCPFixture.app"
mkdir -p "$staging_app/Contents/MacOS"
install -m 0755 "$bin_path/computer-use-mcp-fixture" "$staging_app/Contents/MacOS/computer-use-mcp-fixture"
install -m 0644 "$package_root/Support/Fixture-Info.plist" "$staging_app/Contents/Info.plist"
codesign --force --sign - --identifier com.jmeguilos.computer-use-mcp.fixture "$staging_app"

[[ "$(plutil -extract CFBundleIdentifier raw -o - "$staging_app/Contents/Info.plist")" == "com.jmeguilos.computer-use-mcp.fixture" ]]
[[ "$(plutil -extract CFBundleExecutable raw -o - "$staging_app/Contents/Info.plist")" == "computer-use-mcp-fixture" ]]
mkdir -p "$(dirname "$fixture_app")"
if [[ -L "$fixture_app" ]]; then
  echo "refusing to replace a symlinked fixture bundle: $fixture_app" >&2
  exit 1
fi
if [[ -e "$fixture_app" ]]; then
  existing_plist="$fixture_app/Contents/Info.plist"
  if [[ ! -d "$fixture_app" || -L "$existing_plist" || ! -f "$existing_plist" ]]; then
    echo "refusing to replace an output that is not an inspectable fixture bundle: $fixture_app" >&2
    exit 1
  fi
  existing_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$existing_plist" 2>/dev/null || true)"
  if [[ "$existing_bundle_id" != "com.jmeguilos.computer-use-mcp.fixture" ]]; then
    echo "refusing to replace an app with a different or unreadable bundle identity: $fixture_app" >&2
    exit 1
  fi
  if [[ "$(stat -f '%u' "$fixture_app")" != "$(id -u)" ]]; then
    echo "refusing to replace a fixture bundle not owned by the current user: $fixture_app" >&2
    exit 1
  fi
  rm -rf "$fixture_app"
fi
ditto "$staging_app" "$fixture_app"

codesign --verify --strict "$fixture_app"

if [[ "$assemble_only" == true ]]; then
  echo "$fixture_app"
  exit 0
fi

echo "Launching local fixture bundle: $fixture_app" >&2
exec "$fixture_app/Contents/MacOS/computer-use-mcp-fixture"
