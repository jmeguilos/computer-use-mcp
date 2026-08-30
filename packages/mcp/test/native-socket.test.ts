import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer, type Server } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import { NativeSocketClient } from "../src/bridge/client.js";

const cleanups: Array<() => Promise<void>> = [];

afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

describe("NativeSocketClient development transport", () => {
  it("adds a bounded absolute deadline to every regular host request", async () => {
    const directory = await mkdtemp(join(tmpdir(), "computer-use-mcp-test-"));
    cleanups.push(() => rm(directory, { recursive: true, force: true }));
    const socketPath = join(directory, "host.sock");
    const authTokenPath = join(directory, "auth.token");
    await writeFile(authTokenPath, "test-auth-token-1234567890", { mode: 0o600 });

    let receivedDeadline: number | undefined;
    const server: Server = createServer(socket => {
      socket.setEncoding("utf8");
      let buffer = "";
      socket.on("data", chunk => {
        buffer += String(chunk);
        for (;;) {
          const newline = buffer.indexOf("\n");
          if (newline < 0) break;
          const request = JSON.parse(buffer.slice(0, newline)) as Record<string, unknown>;
          buffer = buffer.slice(newline + 1);
          const id = String(request.id);
          if (request.method === "hello") {
            socket.write(
              `${JSON.stringify({
                protocol: { major: 2, minor: 0 },
                id,
                ok: true,
                result: {
                  connectionId: "11111111-1111-4111-8111-111111111111",
                  connectionToken: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                  acceptedCapabilities: [],
                  idleExpiresAt: "2099-01-01T00:00:00.000Z"
                }
              })}\n`
            );
          } else {
            receivedDeadline = request.deadlineUnixMs as number;
            socket.write(
              `${JSON.stringify({
                protocol: { major: 2, minor: 0 },
                id,
                ok: true,
                result: { completed: true }
              })}\n`
            );
          }
        }
      });
    });
    cleanups.push(
      () =>
        new Promise<void>(resolve => {
          server.close(() => resolve());
        })
    );
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(socketPath, resolve);
    });

    const client = new NativeSocketClient({
      socketPath,
      authTokenPath,
      requestTimeoutMs: 1_000
    });
    cleanups.push(() => client.close());
    const before = Date.now();
    await client.call("action", { kind: "click" }, { timeoutMs: 1_000 });
    const after = Date.now();
    expect(receivedDeadline).toBeGreaterThanOrEqual(before + 1_000);
    expect(receivedDeadline).toBeLessThanOrEqual(after + 1_000);

    const accessBefore = Date.now();
    await client.call("requestAccess", { reason: "Choose a window" }, { timeoutMs: 120_000 });
    const accessAfter = Date.now();
    expect(receivedDeadline).toBeGreaterThanOrEqual(accessBefore + 120_000);
    expect(receivedDeadline).toBeLessThanOrEqual(accessAfter + 120_000);
    await expect(
      client.call("action", { kind: "click" }, { timeoutMs: 30_001 })
    ).rejects.toMatchObject({ code: "BRIDGE_PROTOCOL_ERROR" });
    await client.close();
  });
});
