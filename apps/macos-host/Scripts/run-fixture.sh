#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
package_root="$(cd "$script_dir/.." && pwd -P)"
fixture_app="$package_root/build/ComputerUseMCPFixture.app"
fixture_executable="$fixture_app/Contents/MacOS/computer-use-mcp-fixture"
assemble_only=false
runtime_smoke=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --assemble-only)
      assemble_only=true
      shift
      ;;
    --runtime-smoke)
      runtime_smoke=true
      shift
      ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

if [[ "$assemble_only" == true && "$runtime_smoke" == true ]]; then
  echo "--assemble-only and --runtime-smoke cannot be combined" >&2
  exit 64
fi

if [[ "$assemble_only" == false ]]; then
  while IFS= read -r process_id; do
    [[ -n "$process_id" ]] || continue
    executable_path="$(/bin/ps -p "$process_id" -o command= 2>/dev/null || true)"
    if [[ "$executable_path" == "$fixture_executable" || "$executable_path" == "$fixture_executable "* ]]; then
      echo "ComputerUseMCPFixture is already running at PID $process_id; quit it before rebuilding." >&2
      exit 73
    fi
  done < <(/usr/bin/pgrep -x computer-use-mcp-fixture 2>/dev/null || true)
fi

swift build --package-path "$package_root" -c release --product computer-use-mcp-fixture >&2
bin_path="$(swift build --package-path "$package_root" -c release --show-bin-path)"
staging_parent="$(mktemp -d "${TMPDIR:-/tmp}/computer-use-mcp-fixture.XXXXXX")"
chmod 0700 "$staging_parent"
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

if [[ "$runtime_smoke" == true ]]; then
  report_path="$staging_parent/runtime-smoke.plist"
  echo "Launching permission-free fixture runtime smoke: $fixture_app" >&2
  /usr/bin/open -n "$fixture_app" --args --runtime-smoke-report "$report_path"

  for _ in {1..200}; do
    [[ -s "$report_path" ]] && break
    /bin/sleep 0.1
  done
  if [[ ! -s "$report_path" ]]; then
    while IFS= read -r process_id; do
      [[ -n "$process_id" ]] || continue
      executable_path="$(/bin/ps -p "$process_id" -o command= 2>/dev/null || true)"
      if [[ "$executable_path" == "$fixture_executable --runtime-smoke-report $report_path" ]]; then
        /bin/kill -TERM "$process_id" 2>/dev/null || true
      fi
    done < <(/usr/bin/pgrep -x computer-use-mcp-fixture 2>/dev/null || true)
    echo "fixture runtime smoke did not produce a report within 20 seconds" >&2
    exit 70
  fi

  /usr/bin/plutil -lint "$report_path" >/dev/null
  report_status="$(/usr/bin/plutil -extract status raw -o - "$report_path")"
  if [[ "$report_status" != "passed" ]]; then
    echo "fixture runtime smoke reported status: $report_status" >&2
    /usr/bin/plutil -p "$report_path" >&2
    exit 1
  fi
  [[ "$(/usr/bin/plutil -extract schemaVersion raw -o - "$report_path")" == "1" ]]
  [[ "$(/usr/bin/plutil -extract mode raw -o - "$report_path")" == "in-process-appkit" ]]
  [[ "$(/usr/bin/plutil -extract baselineWindowCount raw -o - "$report_path")" == "2" ]]
  [[ "$(/usr/bin/plutil -extract exercisedWindowCount raw -o - "$report_path")" == "3" ]]
  [[ "$(/usr/bin/plutil -extract privacyPermissionsRequired raw -o - "$report_path")" == "false" ]]
  [[ "$(/usr/bin/plutil -extract checks.11 raw -o - "$report_path")" == "popover-presentation" ]]
  echo "Fixture runtime smoke passed:" >&2
  /usr/bin/plutil -p "$report_path" >&2
  echo "$fixture_app"
  exit 0
fi

echo "Launching local fixture bundle: $fixture_app" >&2
# Launch through Launch Services so NSRunningApplication supplies the process
# generation metadata that the host deliberately binds into every grant.
exec /usr/bin/open -W -n "$fixture_app"
