#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
native_package="$repository_root/apps/macos-host"
info_plist="$native_package/Support/Info.plist"
host_product="ComputerUseMCPHost"
bridge_product="ComputerUseMCPBridge"
host_bundle_id="com.jmeguilos.computer-use-mcp.host"
bridge_bundle_id="com.jmeguilos.computer-use-mcp.bridge"
release_version="0.1.0-alpha.1"
adhoc_sign=false
launch_onboarding=true

usage() {
  cat >&2 <<'USAGE'
Usage: scripts/setup-local.sh --adhoc-sign [--no-launch]

Build and install an explicit source-development copy of ComputerUseMCPHost.app.
This never changes the TCC database, uses sudo, publishes, or creates a login item.
USAGE
}

while (($# > 0)); do
  case "$1" in
    --adhoc-sign) adhoc_sign=true ;;
    --no-launch) launch_onboarding=false ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown setup option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Local host setup requires macOS." >&2
  exit 2
fi
if [[ "$adhoc_sign" != true ]]; then
  echo "Refusing an ambiguous local install. Pass --adhoc-sign to opt into development-only ad-hoc signing." >&2
  exit 2
fi
for command_path in /bin/kill /bin/ps /usr/bin/codesign /usr/bin/id /usr/bin/open /usr/bin/plutil /usr/bin/stat /usr/bin/swift; do
  if [[ ! -x "$command_path" ]]; then
    echo "Required macOS tool is missing: $command_path" >&2
    exit 2
  fi
done
if [[ ! -f "$native_package/Package.swift" || ! -f "$info_plist" ]]; then
  echo "Native package or host Info.plist is missing from the source tree." >&2
  exit 2
fi
if [[ -L "$native_package" || -L "$info_plist" ]]; then
  echo "Refusing symlinked native package metadata." >&2
  exit 2
fi

declared_bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info_plist")"
declared_executable="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$info_plist")"
declared_ui_element="$(/usr/bin/plutil -extract LSUIElement raw -o - "$info_plist")"
declared_release_version="$(/usr/bin/plutil -extract ComputerUseMCPReleaseVersion raw -o - "$info_plist")"
if [[ "$declared_bundle_id" != "$host_bundle_id" || "$declared_executable" != "$host_product" || "$declared_ui_element" != "true" ]]; then
  echo "Host Info.plist does not match the expected bundle identity or LSUIElement policy." >&2
  exit 2
fi
if [[ "$declared_release_version" != "$release_version" ]]; then
  echo "Host Info.plist release version does not match $release_version." >&2
  exit 2
fi

echo "Building native source products in release configuration..." >&2
/usr/bin/swift build --package-path "$native_package" --configuration release --product "$host_product"
/usr/bin/swift build --package-path "$native_package" --configuration release --product "$bridge_product"
binary_directory="$(/usr/bin/swift build --package-path "$native_package" --configuration release --show-bin-path)"
host_binary="$binary_directory/$host_product"
bridge_binary="$binary_directory/$bridge_product"

current_uid="$(/usr/bin/id -u)"
for product in "$host_binary" "$bridge_binary"; do
  if [[ ! -f "$product" || ! -x "$product" || -L "$product" ]]; then
    echo "Expected executable product is missing, non-executable, or symlinked: $product" >&2
    exit 1
  fi
  if [[ "$(/usr/bin/stat -f '%u' "$product")" != "$current_uid" ]]; then
    echo "Refusing a build product not owned by the current user: $product" >&2
    exit 1
  fi
done

current_user="$(/usr/bin/id -un)"
user_home="$(/usr/bin/dscl . -read "/Users/$current_user" NFSHomeDirectory | /usr/bin/awk '{print $2}')"
if [[ -z "$user_home" || "$user_home" != /* || ! -d "$user_home" || -L "$user_home" ]]; then
  echo "Could not resolve a safe local home directory for $current_user." >&2
  exit 1
fi
applications_directory="$user_home/Applications"
if [[ ! -e "$applications_directory" ]]; then
  /usr/bin/install -d -m 0755 "$applications_directory"
fi
if [[ ! -d "$applications_directory" || -L "$applications_directory" || ! -w "$applications_directory" ]]; then
  echo "Per-user Applications directory is unavailable, symlinked, or not writable." >&2
  exit 1
fi
if [[ "$(/usr/bin/stat -f '%u' "$applications_directory")" != "$current_uid" ]]; then
  echo "Per-user Applications directory is not owned by the current user." >&2
  exit 1
fi

destination="$applications_directory/ComputerUseMCPHost.app"
if [[ -L "$destination" ]]; then
  echo "Refusing to replace a symlinked app destination: $destination" >&2
  exit 1
fi
if [[ -e "$destination" ]]; then
  existing_bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$destination/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$existing_bundle_id" != "$host_bundle_id" ]]; then
    echo "Refusing to replace an app with a different or unreadable bundle identity: $destination" >&2
    exit 1
  fi
fi

# Never replace an on-disk bundle while an older copy from that exact path is
# still running. Stop only the current user's expected host path; a same-name
# process from any other path is an ambiguity that requires manual resolution.
expected_host_path="$destination/Contents/MacOS/$host_product"
running_host_pids=()
while read -r process_id process_uid executable_path; do
  [[ -n "${process_id:-}" && -n "${process_uid:-}" && -n "${executable_path:-}" ]] || continue
  [[ "$process_uid" == "$current_uid" && "${executable_path##*/}" == "$host_product" ]] || continue
  if [[ "$executable_path" != "$expected_host_path" ]]; then
    echo "Refusing setup while a same-name host runs from an unexpected path: $executable_path" >&2
    exit 1
  fi
  running_host_pids+=("$process_id")
done < <(/bin/ps -axo pid=,uid=,comm=)

for process_id in "${running_host_pids[@]}"; do
  /bin/kill -TERM "$process_id" 2>/dev/null || true
done
for process_id in "${running_host_pids[@]}"; do
  stopped=false
  for _ in {1..50}; do
    if ! /bin/kill -0 "$process_id" 2>/dev/null; then
      stopped=true
      break
    fi
    /bin/sleep 0.1
  done
  if [[ "$stopped" != true ]]; then
    echo "The existing host did not stop cleanly (PID $process_id); quit it and retry setup." >&2
    exit 1
  fi
done

staging_root="$(/usr/bin/mktemp -d "$applications_directory/.computer-use-mcp-setup.XXXXXX")"
backup_path=""
installed_new=false
setup_succeeded=false
cleanup() {
  if [[ -n "${staging_root:-}" && -d "$staging_root" ]]; then
    /bin/rm -rf "$staging_root"
  fi
  if [[ "$setup_succeeded" != true && "$installed_new" == true && -e "$destination" ]]; then
    /bin/rm -rf "$destination"
  fi
  if [[ -n "${backup_path:-}" && -e "$backup_path" && ! -e "$destination" ]]; then
    /bin/mv "$backup_path" "$destination"
  fi
}
trap cleanup EXIT

staged_app="$staging_root/ComputerUseMCPHost.app"
/usr/bin/install -d -m 0755 \
  "$staged_app/Contents/MacOS" \
  "$staged_app/Contents/Helpers" \
  "$staged_app/Contents/Resources"
/usr/bin/install -m 0644 "$info_plist" "$staged_app/Contents/Info.plist"
/usr/bin/install -m 0755 "$host_binary" "$staged_app/Contents/MacOS/$host_product"
/usr/bin/install -m 0755 "$bridge_binary" "$staged_app/Contents/Helpers/$bridge_product"

echo "Applying explicit development-only ad-hoc signatures..." >&2
/usr/bin/codesign --force --sign - --timestamp=none \
  --identifier "$bridge_bundle_id" \
  "$staged_app/Contents/Helpers/$bridge_product"
/usr/bin/codesign --force --sign - --timestamp=none "$staged_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$staged_app"

for installed_binary in \
  "$staged_app/Contents/MacOS/$host_product" \
  "$staged_app/Contents/Helpers/$bridge_product"; do
  mode="$(/usr/bin/stat -f '%Lp' "$installed_binary")"
  if [[ "$mode" != "755" || ! -x "$installed_binary" ]]; then
    echo "Staged executable has an unsafe mode: $installed_binary ($mode)" >&2
    exit 1
  fi
done

if [[ -e "$destination" ]]; then
  backup_path="$applications_directory/.ComputerUseMCPHost.app.backup.$(/usr/bin/uuidgen)"
  /bin/mv "$destination" "$backup_path"
fi
if ! /bin/mv "$staged_app" "$destination"; then
  echo "Could not install the staged app." >&2
  exit 1
fi
installed_new=true

installed_bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$destination/Contents/Info.plist")"
if [[ "$installed_bundle_id" != "$host_bundle_id" || \
      ! -x "$destination/Contents/MacOS/$host_product" || \
      ! -x "$destination/Contents/Helpers/$bridge_product" ]]; then
  echo "Installed app validation failed." >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$destination"

# Development peer verification is enabled only when both the caller requests
# it and this fixed, per-user marker is present. A Developer ID-signed host
# ignores the marker and always uses its release signing requirement.
runtime_directory="$user_home/Library/Application Support/ComputerUseMCP/runtime"
if [[ -L "$user_home/Library/Application Support/ComputerUseMCP" || -L "$runtime_directory" ]]; then
  echo "Refusing a symlinked Computer Use MCP runtime path." >&2
  exit 1
fi
/usr/bin/install -d -m 0700 "$runtime_directory"
/bin/chmod 0700 "$runtime_directory"
if [[ "$(/usr/bin/stat -f '%u' "$runtime_directory")" != "$current_uid" || \
      "$(/usr/bin/stat -f '%Lp' "$runtime_directory")" != "700" ]]; then
  echo "Development runtime directory has an unsafe owner or mode." >&2
  exit 1
fi
marker_path="$runtime_directory/source-development-mode"
marker_staging="$(/usr/bin/mktemp "$runtime_directory/.source-development-mode.XXXXXX")"
/bin/chmod 0600 "$marker_staging"
printf 'ComputerUseMCP source development v1\n' > "$marker_staging"
/bin/mv -f "$marker_staging" "$marker_path"
if [[ -L "$marker_path" || \
      "$(/usr/bin/stat -f '%u' "$marker_path")" != "$current_uid" || \
      "$(/usr/bin/stat -f '%Lp' "$marker_path")" != "600" ]]; then
  echo "Development authorization marker has an unsafe owner, mode, or type." >&2
  exit 1
fi

setup_succeeded=true
if [[ -n "$backup_path" && -e "$backup_path" ]]; then
  /bin/rm -rf "$backup_path"
  backup_path=""
fi

echo "Installed development host at $destination" >&2
echo "Created the explicit source-development authorization marker." >&2
if [[ "$launch_onboarding" == true ]]; then
  echo "Launching permission onboarding; approve only the access you intend to use." >&2
  /usr/bin/open "$destination" --args --development-mode --onboarding
else
  echo "Launch skipped; open the app with --development-mode before running doctor." >&2
fi
