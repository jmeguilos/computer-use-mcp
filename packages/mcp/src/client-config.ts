import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

// Conservative JSON/TOML merge patterns adapted from the MIT-licensed
// open-codex-computer-use installer at revision 503a5e54c812cde33c2f986f6199d16f7171538f.
// The complete retained notice is distributed with this package.

export type SupportedClient = "claude-desktop" | "claude-code" | "cursor" | "codex";

export type StdioEntry = {
  command: string;
  args: string[];
};

function readObject(path: string): Record<string, unknown> {
  if (!existsSync(path)) return {};
  const text = readFileSync(path, "utf8");
  if (text.trim() === "") return {};
  const value: unknown = JSON.parse(text);
  if (value === null || Array.isArray(value) || typeof value !== "object") {
    throw new Error(`Existing client configuration is not a JSON object: ${path}`);
  }
  return value as Record<string, unknown>;
}

function objectField(parent: Record<string, unknown>, key: string): Record<string, unknown> {
  const existing = parent[key];
  if (existing === undefined) {
    const created: Record<string, unknown> = {};
    parent[key] = created;
    return created;
  }
  if (existing === null || Array.isArray(existing) || typeof existing !== "object") {
    throw new Error(`Existing ${key} field is not an object; refusing to overwrite it.`);
  }
  return existing as Record<string, unknown>;
}

export function mergeJSONClientConfig(
  existing: Record<string, unknown>,
  entry: StdioEntry
): Record<string, unknown> {
  const servers = objectField(existing, "mcpServers");
  servers["computer-use-mcp"] = entry;
  return existing;
}

type TomlSection = { header: string; body: string[] };

function parseTomlSections(text: string): { preamble: string[]; sections: TomlSection[] } {
  const preamble: string[] = [];
  const sections: TomlSection[] = [];
  let current: TomlSection | undefined;
  for (const line of text.replaceAll("\r\n", "\n").split("\n")) {
    const match = /^\[([^\]]+)]\s*$/.exec(line);
    if (match?.[1] !== undefined) {
      current = { header: match[1], body: [] };
      sections.push(current);
    } else if (current === undefined) {
      preamble.push(line);
    } else {
      current.body.push(line);
    }
  }
  return { preamble, sections };
}

function trimBlankTail(lines: string[]): string[] {
  const result = [...lines];
  while (result.at(-1)?.trim() === "") result.pop();
  return result;
}

export function mergeCodexConfig(existing: string, entry: StdioEntry): string {
  const target = "mcp_servers.computer-use-mcp";
  const document = parseTomlSections(existing);
  if (document.sections.filter(section => section.header === target).length > 1) {
    throw new Error(`Existing Codex config has duplicate [${target}] sections.`);
  }
  const body = [
    `command = ${JSON.stringify(entry.command)}`,
    `args = ${JSON.stringify(entry.args)}`
  ];
  const retained = document.sections.filter(section => section.header !== target);
  retained.push({ header: target, body });
  const chunks: string[] = [];
  const preamble = trimBlankTail(document.preamble);
  if (preamble.some(line => line.trim() !== "")) chunks.push(preamble.join("\n"));
  for (const section of retained) {
    const sectionBody = trimBlankTail(section.body);
    chunks.push(
      sectionBody.length === 0
        ? `[${section.header}]`
        : `[${section.header}]\n${sectionBody.join("\n")}`
    );
  }
  return `${chunks.join("\n\n")}\n`;
}

export function installClientConfig(input: {
  client: SupportedClient;
  path: string;
  entry: StdioEntry;
}): void {
  const path = resolve(input.path);
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  if (input.client === "codex") {
    const existing = existsSync(path) ? readFileSync(path, "utf8") : "";
    writeFileSync(path, mergeCodexConfig(existing, input.entry), { mode: 0o600 });
    return;
  }
  const merged = mergeJSONClientConfig(readObject(path), input.entry);
  writeFileSync(path, `${JSON.stringify(merged, null, 2)}\n`, { mode: 0o600 });
}
