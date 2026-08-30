#!/usr/bin/env node

import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const read = path => readFileSync(`${root}/${path}`, "utf8");
const json = path => JSON.parse(read(path));
const failures = [];

function requireEqual(label, actual, expected) {
  if (actual !== expected) failures.push(`${label}: expected ${expected}, received ${actual}`);
}

function requireContains(path, value, label) {
  if (!read(path).includes(value)) failures.push(`${label}: ${path} does not contain ${value}`);
}

function captured(path, pattern, label) {
  const match = read(path).match(pattern);
  if (match?.[1] === undefined) {
    failures.push(`${label}: value was not found in ${path}`);
    return undefined;
  }
  return match[1];
}

function plistString(path, key) {
  const escaped = key.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  return captured(
    path,
    new RegExp(`<key>\\s*${escaped}\\s*</key>\\s*<string>([^<]+)</string>`, "u"),
    `${path}:${key}`
  );
}

const workspace = json("package.json");
const mcp = json("packages/mcp/package.json");
const protocol = json("packages/protocol/package.json");
const lock = json("package-lock.json");
const releaseVersion = mcp.version;
const bundleVersion = releaseVersion.split("-", 1)[0];
const releaseTag = `v${releaseVersion}`;

requireEqual("workspace package", workspace.version, releaseVersion);
requireEqual("protocol package", protocol.version, releaseVersion);
requireEqual("lockfile root", lock.version, releaseVersion);
requireEqual("lockfile workspace root", lock.packages?.[""]?.version, releaseVersion);
requireEqual("lockfile MCP package", lock.packages?.["packages/mcp"]?.version, releaseVersion);
requireEqual("lockfile protocol package", lock.packages?.["packages/protocol"]?.version, releaseVersion);
requireEqual(
  "shared protocol constant",
  captured(
    "packages/protocol/src/constants.ts",
    /PACKAGE_VERSION\s*=\s*"([^"]+)"/u,
    "PACKAGE_VERSION"
  ),
  releaseVersion
);

const sharedProtocol = read("packages/protocol/src/constants.ts").match(
  /PROTOCOL_VERSION\s*=.*?major:\s*(\d+),\s*minor:\s*(\d+)/su
);
const adapterProtocol = read("packages/mcp/src/bridge/protocol.ts").match(
  /NATIVE_PROTOCOL\s*=.*?major:\s*(\d+),\s*minor:\s*(\d+)/su
);
const nativeProtocol = read("apps/macos-host/Sources/MacOSHostCore/Models.swift").match(
  /static let current\s*=\s*ProtocolVersion\(major:\s*(\d+),\s*minor:\s*(\d+)\)/u
);
for (const [label, match] of [
  ["shared protocol", sharedProtocol],
  ["standalone adapter protocol", adapterProtocol],
  ["native host protocol", nativeProtocol]
]) {
  if (match?.[1] === undefined || match[2] === undefined) {
    failures.push(`${label}: protocol version was not found`);
  }
}
const protocolVersion = sharedProtocol?.[1] !== undefined && sharedProtocol[2] !== undefined
  ? `${sharedProtocol[1]}.${sharedProtocol[2]}`
  : undefined;
if (protocolVersion !== undefined) {
  requireEqual(
    "standalone adapter protocol",
    adapterProtocol?.[1] === undefined || adapterProtocol[2] === undefined
      ? undefined
      : `${adapterProtocol[1]}.${adapterProtocol[2]}`,
    protocolVersion
  );
  requireEqual(
    "native host protocol",
    nativeProtocol?.[1] === undefined || nativeProtocol[2] === undefined
      ? undefined
      : `${nativeProtocol[1]}.${nativeProtocol[2]}`,
    protocolVersion
  );
  requireContains("docs/PROTOCOL.md", `protocol version is \`${protocolVersion}\``, "protocol documentation");

  const fixtureSuffix = `-v${sharedProtocol[1]}.json`;
  const bridgeFixtures = readdirSync(`${root}/packages/protocol/fixtures`)
    .filter(name => name.startsWith("bridge-"));
  if (bridgeFixtures.length === 0 || bridgeFixtures.some(name => !name.endsWith(fixtureSuffix))) {
    failures.push(`protocol fixtures: every bridge fixture must end in ${fixtureSuffix}`);
  }
}

requireContains("README.md", `**Alpha status:** \`${releaseTag}\``, "README release version");
requireContains(
  "SECURITY.md",
  `| \`${releaseVersion}\` | Release candidate; not tagged |`,
  "security candidate version"
);
requireContains("docs/RELEASING.md", `tag \`${releaseTag}\``, "release checklist tag");
requireContains(
  ".github/workflows/release-source.yml",
  `test \"$package_version\" = \"${releaseVersion}\"`,
  "source workflow package version"
);

if (process.env.GITHUB_REF_TYPE === "tag") {
  requireEqual("workflow tag", process.env.GITHUB_REF_NAME, releaseTag);
}
requireEqual(
  "MCP server constant",
  captured("packages/mcp/src/server.ts", /SERVER_VERSION\s*=\s*"([^"]+)"/u, "SERVER_VERSION"),
  releaseVersion
);
requireEqual(
  "native host constant",
  captured(
    "apps/macos-host/Sources/MacOSHostCore/HostController.swift",
    /"nativeVersion"\s*:\s*\.string\("([^"]+)"\)/u,
    "nativeVersion"
  ),
  releaseVersion
);
requireEqual(
  "local setup constant",
  captured("scripts/setup-local.sh", /^release_version="([^"]+)"/mu, "release_version"),
  releaseVersion
);
requireEqual(
  "pack verification constant",
  captured(
    "scripts/verify-pack.sh",
    /manifest\.version\s*!==\s*"([^"]+)"/u,
    "pack manifest version"
  ),
  releaseVersion
);

for (const plist of [
  "apps/macos-host/Support/Info.plist",
  "apps/macos-host/Support/Fixture-Info.plist"
]) {
  requireEqual(`${plist} short version`, plistString(plist, "CFBundleShortVersionString"), bundleVersion);
  requireEqual(`${plist} release version`, plistString(plist, "ComputerUseMCPReleaseVersion"), releaseVersion);
}

if (failures.length !== 0) {
  for (const failure of failures) process.stderr.write(`version verification failed: ${failure}\n`);
  process.exit(1);
}

process.stdout.write(`${JSON.stringify({ ok: true, release_version: releaseVersion, bundle_version: bundleVersion })}\n`);
