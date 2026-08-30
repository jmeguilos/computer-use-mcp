#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import {
  closeSync,
  constants,
  fstatSync,
  openSync,
  readFileSync,
  realpathSync
} from "node:fs";
import { dirname, extname, isAbsolute, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { TextDecoder } from "node:util";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = realpathSync(resolve(scriptDirectory, ".."));
const maximumFiles = 20_000;
const maximumSourceBytes = 2 * 1024 * 1024;
if (typeof constants.O_NOFOLLOW !== "number") {
  throw new Error("The provenance scanner requires O_NOFOLLOW support");
}

const requiredFiles = [
  "LICENSE",
  "NOTICE",
  "README.md",
  "SECURITY.md",
  "THIRD_PARTY_NOTICES.md",
  "docs/PROVENANCE.md"
];

const ignoredPrefixes = [
  ".git/",
  ".build/",
  ".swiftpm/",
  "DerivedData/",
  "artifacts/",
  "coverage/",
  "dist/",
  "node_modules/",
  "sbom/npm.cdx.json",
  "sbom/project.spdx.json",
  "sbom/swift-dependencies.json"
];

const prohibitedPathComponents = new Set([
  "asset-dump",
  "binary-dump",
  "decompiled",
  "disassembly",
  "extracted",
  "third-party",
  "third_party",
  "upstream-snapshot",
  "vendor",
  "vendored"
]);

const prohibitedExtensions = new Set([
  ".7z",
  ".a",
  ".app",
  ".bin",
  ".bz2",
  ".car",
  ".dll",
  ".dmg",
  ".dylib",
  ".exe",
  ".gz",
  ".o",
  ".pkg",
  ".rar",
  ".so",
  ".tar",
  ".tgz",
  ".xcarchive",
  ".xip",
  ".xz",
  ".zip"
]);

const executableMagic = new Map([
  ["7f454c46", "ELF executable"],
  ["4d5a", "Windows executable"],
  ["cafebabe", "Mach-O universal binary or Java class"],
  ["cafebabf", "Mach-O universal binary"],
  ["bebafeca", "Mach-O universal binary"],
  ["cefaedfe", "Mach-O executable"],
  ["cffaedfe", "Mach-O executable"],
  ["feedface", "Mach-O executable"],
  ["feedfacf", "Mach-O executable"],
  ["78617221", "XAR/package archive"],
  ["504b0304", "ZIP archive"],
  ["1f8b", "gzip archive"]
]);

const credentialMarkers = [
  /-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----/u,
  /\bAKIA[0-9A-Z]{16}\b/u,
  /\bgh[pousr]_[A-Za-z0-9_]{32,}\b/u,
  /\bnpm_[A-Za-z0-9]{30,}\b/u
];

function normalizedPath(path) {
  return path.split(sep).join("/").replace(/^\.\//u, "");
}

function gitFiles(arguments_) {
  const output = execFileSync(
    "git",
    ["ls-files", ...arguments_, "-z"],
    { cwd: repositoryRoot, encoding: "buffer", stdio: ["ignore", "pipe", "pipe"] }
  );
  return output
    .toString("utf8")
    .split("\0")
    .filter(Boolean)
    .map(normalizedPath);
}

function sourceFiles() {
  const tracked = gitFiles(["--cached"]);
  const untracked = gitFiles(["--others", "--exclude-standard"])
    .filter(path => !ignoredPrefixes.some(prefix => path === prefix || path.startsWith(prefix)));
  return {
    files: [...new Set([...tracked, ...untracked])]
      .sort((left, right) => left.localeCompare(right)),
    tracked: new Set(tracked)
  };
}

function privateDenyTerms() {
  const raw = process.env.PROVENANCE_DENY_TERMS;
  if (raw === undefined || raw.trim() === "") return [];

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error("PROVENANCE_DENY_TERMS must be a JSON array of literal strings");
  }
  if (!Array.isArray(parsed) || parsed.length > 100) {
    throw new Error("PROVENANCE_DENY_TERMS must contain at most 100 strings");
  }
  return parsed.map(value => {
    if (typeof value !== "string" || value.trim().length < 3 || value.length > 512) {
      throw new Error("Each private provenance deny term must be a 3-512 character string");
    }
    return value.toLocaleLowerCase("en-US");
  });
}

function requirePrivateDenyTerms() {
  const raw = process.env.PROVENANCE_REQUIRE_DENY_TERMS;
  if (raw === undefined || raw === "" || raw === "0") return false;
  if (raw === "1") return true;
  throw new Error("PROVENANCE_REQUIRE_DENY_TERMS must be 0 or 1");
}

function looksLikeWorkflow(path) {
  return /^\.github\/workflows\/[^/]+\.ya?ml$/u.test(path);
}

function checkWorkflow(path, text, failures) {
  for (const [index, line] of text.split("\n").entries()) {
    const use = line.match(/^\s*-?\s*uses:\s*["']?([^\s"']+)["']?\s*(?:#.*)?$/u);
    if (use !== null) {
      const reference = use[1];
      if (!reference.startsWith("./") && !/@[0-9a-f]{40}$/u.test(reference)) {
        failures.push(`${path}:${index + 1}: GitHub Action is not pinned to a full commit SHA`);
      }
    }

    if (/^\s*(?:run:\s*)?(?:npm\s+(?:publish|unpublish|deprecate)|pnpm\s+publish|yarn\s+npm\s+publish)\b/iu.test(line)) {
      failures.push(`${path}:${index + 1}: registry publication command is forbidden in alpha workflows`);
    }
    if (/(?:curl|wget)\b[^\n|]*\|\s*(?:ba)?sh\b/iu.test(line)) {
      failures.push(`${path}:${index + 1}: downloaded content must not be piped directly to a shell`);
    }
  }
}

function magicDescription(buffer) {
  const prefix = buffer.subarray(0, 4).toString("hex").toLocaleLowerCase("en-US");
  for (const [magic, description] of executableMagic) {
    if (prefix.startsWith(magic)) return description;
  }
  return undefined;
}

const failures = [];
let files;
let trackedFiles;
let denyTerms;

try {
  ({ files, tracked: trackedFiles } = sourceFiles());
  denyTerms = privateDenyTerms();
  if (requirePrivateDenyTerms() && denyTerms.length === 0) {
    throw new Error("protected provenance scans require nonempty private deny terms");
  }
} catch (error) {
  process.stderr.write(`provenance scan configuration failed: ${error.message}\n`);
  process.exit(2);
}

if (files.length === 0 || files.length > maximumFiles) {
  failures.push(`source file count ${files.length} is outside the allowed range 1-${maximumFiles}`);
}

const fileSet = new Set(files);
for (const required of requiredFiles) {
  if (!fileSet.has(required)) failures.push(`${required}: required provenance/legal file is missing`);
}

const decoder = new TextDecoder("utf-8", { fatal: true });

for (const path of files) {
  if (trackedFiles.has(path) &&
      ignoredPrefixes.some(prefix => path === prefix || path.startsWith(prefix))) {
    failures.push(`${path}: tracked files are forbidden in ignored generated/dependency paths`);
  }

  const absolutePath = resolve(repositoryRoot, path);
  const relativePath = relative(repositoryRoot, absolutePath);
  if (isAbsolute(relativePath) || relativePath.startsWith(`..${sep}`) || relativePath === "..") {
    failures.push(`${path}: resolves outside the repository`);
    continue;
  }

  let descriptor;
  let stat;
  let buffer;
  try {
    descriptor = openSync(absolutePath, constants.O_RDONLY | constants.O_NOFOLLOW);
    const resolvedOpenPath = realpathSync(absolutePath);
    const resolvedRelativePath = relative(repositoryRoot, resolvedOpenPath);
    if (isAbsolute(resolvedRelativePath) ||
        resolvedRelativePath.startsWith(`..${sep}`) || resolvedRelativePath === "..") {
      failures.push(`${path}: opened file resolves outside the repository`);
      continue;
    }
    stat = fstatSync(descriptor, { bigint: true });
    if (!stat.isFile()) continue;

    if (stat.size > BigInt(maximumSourceBytes)) {
      failures.push(`${path}: source file exceeds ${maximumSourceBytes} bytes`);
      continue;
    }

    buffer = readFileSync(descriptor);
    const postReadStat = fstatSync(descriptor, { bigint: true });
    if (postReadStat.dev !== stat.dev || postReadStat.ino !== stat.ino ||
        postReadStat.size !== stat.size || postReadStat.mtimeNs !== stat.mtimeNs ||
        postReadStat.ctimeNs !== stat.ctimeNs) {
      failures.push(`${path}: file changed while it was being scanned`);
      continue;
    }
  } catch (error) {
    if (error?.code === "ELOOP") {
      failures.push(`${path}: symbolic links are not allowed in the source-only alpha`);
    } else {
      failures.push(`${path}: cannot be opened safely`);
    }
    continue;
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }

  const components = path.toLocaleLowerCase("en-US").split("/");
  const prohibitedComponent = components.find(component => prohibitedPathComponents.has(component));
  if (prohibitedComponent !== undefined) {
    failures.push(`${path}: prohibited source-material directory`);
  }

  if (prohibitedExtensions.has(extname(path).toLocaleLowerCase("en-US"))) {
    failures.push(`${path}: packaged/binary artifact extension is forbidden in the source-only alpha`);
  }

  const description = magicDescription(buffer);
  if (description !== undefined) failures.push(`${path}: detected ${description}`);
  if (buffer.includes(0)) {
    failures.push(`${path}: binary NUL byte detected`);
    continue;
  }

  let text;
  try {
    text = decoder.decode(buffer);
  } catch {
    failures.push(`${path}: file is not valid UTF-8 source text`);
    continue;
  }

  for (const marker of credentialMarkers) {
    if (marker.test(text)) failures.push(`${path}: possible private credential material`);
  }

  const lowerPath = path.toLocaleLowerCase("en-US");
  const lowerText = text.toLocaleLowerCase("en-US");
  if (denyTerms.some(term => lowerPath.includes(term) || lowerText.includes(term))) {
    failures.push(`${path}: matches a private provenance deny term`);
  }

  if (looksLikeWorkflow(path)) checkWorkflow(path, text, failures);
}

if (failures.length > 0) {
  process.stderr.write("Provenance scan failed:\n");
  for (const failure of [...new Set(failures)].sort()) {
    process.stderr.write(`- ${failure}\n`);
  }
  process.exit(1);
}

process.stdout.write(`Provenance scan passed: ${files.length} source files checked.\n`);
