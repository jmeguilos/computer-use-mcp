#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_directory="$repository_root/sbom"

mkdir -p "$output_directory"
cd "$repository_root"

npm exec -- cyclonedx-npm \
  --output-format JSON \
  --output-file "$output_directory/npm.cdx.json" \
  --spec-version 1.6

swift package \
  --package-path "$repository_root/apps/macos-host" \
  show-dependencies \
  --format json > "$output_directory/swift-dependencies.json"

echo "Generated dependency manifests in $output_directory" >&2
