#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host_package="$repository_root/apps/macos-host"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Universal host builds require macOS." >&2
  exit 2
fi

if [[ ! -f "$host_package/Package.swift" ]]; then
  echo "Native host package is missing: $host_package/Package.swift" >&2
  exit 2
fi

swift build \
  --package-path "$host_package" \
  --configuration release \
  --arch arm64 \
  --arch x86_64

echo "Universal source build completed. No unsigned artifact was published." >&2
