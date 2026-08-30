import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
import { describe, expect, it } from "vitest";

const cli = fileURLToPath(new URL("../dist/index.js", import.meta.url));

describe("stdio CLI compatibility", () => {
  for (const era of ["legacy", "modern"] as const) {
    it(
      `keeps stdout as clean MCP framing for a ${era} client`,
      async () => {
        const transport = new StdioClientTransport({
          command: process.execPath,
          args: [cli],
          stderr: "pipe"
        });
        const client = new Client(
          { name: `${era}-stdio-test`, version: "1.0.0" },
          era === "modern"
            ? { versionNegotiation: { mode: { pin: "2026-07-28" } } }
            : undefined
        );
        try {
          await client.connect(transport);
          const { tools } = await client.listTools();
          expect(tools).toHaveLength(15);
        } finally {
          await client.close();
        }
      },
      15_000
    );
  }
});
