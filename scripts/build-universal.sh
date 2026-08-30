#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host_package="$repository_root/apps/macos-host"
deployment_target="14.4"
products=(
  ComputerUseMCPHost
  ComputerUseMCPBridge
  computer-use-mcp-fixture
)

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Universal host builds require macOS." >&2
  exit 2
fi

if [[ ! -f "$host_package/Package.swift" ]]; then
  echo "Native host package is missing: $host_package/Package.swift" >&2
  exit 2
fi

for required_tool in /usr/bin/lipo /usr/bin/mktemp /usr/bin/install; do
  if [[ ! -x "$required_tool" ]]; then
    echo "Universal build tool is missing: $required_tool" >&2
    exit 2
  fi
done

# SwiftPM's multi-value --arch route is implemented through an Xcode-generated
# package project on some toolchains. That route can assign multiple products
# the same intermediate output. Build each target triple in an isolated scratch
# tree, then combine only the validated executable products.
scratch_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/computer-use-mcp-universal.XXXXXX")"
cleanup() {
  /bin/rm -rf "$scratch_root"
}
trap cleanup EXIT

arm_binary_directory=""
intel_binary_directory=""
for architecture in arm64 x86_64; do
  scratch_path="$scratch_root/$architecture"
  target_triple="${architecture}-apple-macosx${deployment_target}"
  for product in "${products[@]}"; do
    swift build \
      --package-path "$host_package" \
      --scratch-path "$scratch_path" \
      --configuration release \
      --triple "$target_triple" \
      --product "$product"
  done
  binary_directory="$(swift build \
    --package-path "$host_package" \
    --scratch-path "$scratch_path" \
    --configuration release \
    --triple "$target_triple" \
    --show-bin-path)"
  case "$architecture" in
    arm64) arm_binary_directory="$binary_directory" ;;
    x86_64) intel_binary_directory="$binary_directory" ;;
  esac
done

staged_products="$scratch_root/universal"
/usr/bin/install -d -m 0755 "$staged_products"
for product in "${products[@]}"; do
  arm_binary="$arm_binary_directory/$product"
  intel_binary="$intel_binary_directory/$product"
  if [[ ! -x "$arm_binary" || ! -x "$intel_binary" ]]; then
    echo "An architecture-specific product is missing or not executable: $product" >&2
    exit 1
  fi
  /usr/bin/lipo -create "$arm_binary" "$intel_binary" -output "$staged_products/$product"
  architectures="$(/usr/bin/lipo -archs "$staged_products/$product")"
  if [[ " $architectures " != *" arm64 "* || " $architectures " != *" x86_64 "* ]]; then
    echo "Universal product has unexpected architectures: $product ($architectures)" >&2
    exit 1
  fi
done

# Keep the stable output path consumed by the disabled signed-release workflow,
# while writing only the three products verified above.
output_directory="$host_package/.build/apple/Products/Release"
/usr/bin/install -d -m 0755 "$output_directory"
for product in "${products[@]}"; do
  /usr/bin/install -m 0755 "$staged_products/$product" "$output_directory/$product"
done

echo "Universal source build completed. No unsigned artifact was published." >&2
