#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pack_directory="$(mktemp -d "${TMPDIR:-/tmp}/computer-use-mcp-pack.XXXXXX")"
cleanup() {
  rm -rf "$pack_directory"
}
trap cleanup EXIT

cd "$repository_root"
npm run build --workspace @jmeguilos/computer-use-mcp
npm pack \
  --workspace @jmeguilos/computer-use-mcp \
  --ignore-scripts \
  --pack-destination "$pack_directory" \
  --json > "$pack_directory/pack.json"

archive="$(find "$pack_directory" -maxdepth 1 -name '*.tgz' -type f -print -quit)"
if [[ -z "$archive" ]]; then
  echo "npm pack did not create an archive." >&2
  exit 1
fi

listing="$pack_directory/listing.txt"
tar -tzf "$archive" > "$listing"

required_files=(
  package/package.json
  package/README.md
  package/LICENSE
  package/THIRD_PARTY_NOTICES.md
  package/dist/index.js
  package/dist/index.d.ts
  package/dist/server.js
  package/dist/server.d.ts
  package/dist/bridge/index.js
  package/dist/bridge/index.d.ts
  package/dist/bridge/process-client.js
  package/dist/bridge/process-client.d.ts
  package/dist/bridge/protocol.js
  package/dist/bridge/protocol.d.ts
)
for required_file in "${required_files[@]}"; do
  if ! grep -Fqx "$required_file" "$listing"; then
    echo "Package is missing required file: $required_file" >&2
    exit 1
  fi
done

if grep -Eiq '(^|/)(node_modules|src|test|tests)/|\.(app|dmg|pkg|xcodearchive|zip|node)$|/ComputerUseMCP(Host|Bridge)$' "$listing"; then
  echo "Package contains development inputs, dependencies, or a native/downloadable artifact." >&2
  exit 1
fi

extract_directory="$pack_directory/extracted"
mkdir -p "$extract_directory"
tar -xzf "$archive" -C "$extract_directory"
if find "$extract_directory/package" -type l -print -quit | grep -q .; then
  echo "Package contains a symbolic link." >&2
  exit 1
fi
if [[ ! -x "$extract_directory/package/dist/index.js" ]]; then
  echo "Package command entry point is not executable." >&2
  exit 1
fi

node - "$archive" "$listing" "$extract_directory/package" <<'NODE'
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { basename, posix } from "node:path";

const archive = process.argv[2];
const listingPath = process.argv[3];
const extractedPackage = process.argv[4];
const entries = readFileSync(listingPath, "utf8").split("\n").filter(Boolean);
for (const entry of entries) {
  const normalized = posix.normalize(entry);
  if (!entry.startsWith("package/") || normalized !== entry || entry.includes("\\")) {
    throw new Error(`Unsafe archive entry: ${entry}`);
  }
}

const packageJson = execFileSync("tar", ["-xOzf", archive, "package/package.json"], {
  encoding: "utf8"
});
const manifest = JSON.parse(packageJson);
const forbiddenLifecycle = [
  "preinstall",
  "install",
  "postinstall",
  "prepack",
  "prepare",
  "prepublish",
  "prepublishOnly"
];
for (const script of forbiddenLifecycle) {
  if (manifest.scripts?.[script]) {
    throw new Error(`Forbidden lifecycle script in packed package: ${script}`);
  }
}
if (manifest.name !== "@jmeguilos/computer-use-mcp") {
  throw new Error(`Unexpected package name: ${manifest.name}`);
}
if (manifest.version !== "0.1.0-alpha.1") {
  throw new Error(`Unexpected package version: ${manifest.version}`);
}
if (manifest.license !== "Apache-2.0") {
  throw new Error(`Unexpected package license: ${manifest.license}`);
}
if (manifest.repository?.url !== "git+https://github.com/jmeguilos/computer-use-mcp.git") {
  throw new Error("Packed package repository identity is incorrect.");
}
if (manifest.bin?.["computer-use-mcp"] !== "dist/index.js") {
  throw new Error("Packed package command entry point is incorrect.");
}
if (manifest.exports?.["."]?.import !== "./dist/server.js" ||
    manifest.exports?.["."]?.types !== "./dist/server.d.ts" ||
    manifest.exports?.["./bridge"]?.import !== "./dist/bridge/index.js" ||
    manifest.exports?.["./bridge"]?.types !== "./dist/bridge/index.d.ts") {
  throw new Error("Packed package exports do not match the verified runtime files.");
}
if (manifest.engines?.node !== ">=20") {
  throw new Error(`Unexpected Node engine: ${manifest.engines?.node}`);
}
const entryPoint = readFileSync(`${extractedPackage}/dist/index.js`, "utf8");
if (!entryPoint.startsWith("#!/usr/bin/env node\n")) {
  throw new Error("Packed command entry point is missing its Node shebang.");
}
process.stderr.write(`Verified source npm archive ${basename(archive)} (${entries.length} entries)\n`);
NODE
