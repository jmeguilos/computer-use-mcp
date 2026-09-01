import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  installClientConfig,
  mergeCodexConfig,
  mergeJSONClientConfig
} from "../src/client-config.js";

const entry = { command: "/usr/bin/node", args: ["/opt/computer-use-mcp/dist/index.js"] };
const temporaryDirectories: string[] = [];

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { recursive: true, force: true });
  }
});

describe("client configuration installer", () => {
  it("merges JSON without deleting unrelated client settings", () => {
    const existing = { theme: "dark", mcpServers: { retained: { command: "retained" } } };
    expect(mergeJSONClientConfig(existing, entry)).toEqual({
      theme: "dark",
      mcpServers: {
        retained: { command: "retained" },
        "computer-use-mcp": entry
      }
    });
  });

  it("replaces one managed Codex section while preserving unrelated TOML", () => {
    const existing = `model = "gpt"\n\n[mcp_servers.retained]\ncommand = "retained"\n\n[mcp_servers.computer-use-mcp]\ncommand = "old"\n`;
    const merged = mergeCodexConfig(existing, entry);
    expect(merged).toContain('model = "gpt"');
    expect(merged).toContain('[mcp_servers.retained]\ncommand = "retained"');
    expect(merged.match(/\[mcp_servers\.computer-use-mcp]/g)).toHaveLength(1);
    expect(merged).toContain('command = "/usr/bin/node"');
    expect(merged).toContain('args = ["/opt/computer-use-mcp/dist/index.js"]');
  });

  it("refuses an ambiguous duplicate managed Codex section", () => {
    const duplicate = "[mcp_servers.computer-use-mcp]\ncommand = \"a\"\n\n[mcp_servers.computer-use-mcp]\ncommand = \"b\"\n";
    expect(() => mergeCodexConfig(duplicate, entry)).toThrow(/duplicate/);
  });

  it("writes a requested client path idempotently", () => {
    const directory = mkdtempSync(join(tmpdir(), "computer-use-client-config-"));
    temporaryDirectories.push(directory);
    const path = join(directory, "nested", "mcp.json");
    writeFileSync(join(directory, "unrelated"), "preserved");

    installClientConfig({ client: "cursor", path, entry });
    installClientConfig({ client: "cursor", path, entry });

    expect(JSON.parse(readFileSync(path, "utf8"))).toEqual({
      mcpServers: { "computer-use-mcp": entry }
    });
    expect(readFileSync(join(directory, "unrelated"), "utf8")).toBe("preserved");
  });
});
