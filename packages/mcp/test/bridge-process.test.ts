import { chmod } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { PassThrough } from "node:stream";
import { beforeAll, describe, expect, it } from "vitest";
import { NativeApprovalRequiredError } from "../src/errors.js";
import { BridgeProcessClient } from "../src/bridge/process-client.js";
import { NATIVE_MAX_LINE_BYTES } from "../src/bridge/protocol.js";

const fixture = fileURLToPath(new URL("./fixtures/fake-bridge.mjs", import.meta.url));

beforeAll(async () => chmod(fixture, 0o755));

describe("BridgeProcessClient", () => {
  it("uses the shared 8 MiB wire-line maximum", () => {
    expect(NATIVE_MAX_LINE_BYTES).toBe(8 * 1024 * 1024);
  });
  it("spawns a private helper, sends a secret-free hello, and forwards stderr only", async () => {
    const stderr = new PassThrough();
    let diagnostics = "";
    stderr.setEncoding("utf8");
    stderr.on("data", chunk => {
      diagnostics += String(chunk);
    });
    const bridge = new BridgeProcessClient({ executablePath: fixture, stderr });
    try {
      const status = (await bridge.call("status", {})) as Record<string, unknown>;
      expect(status).toMatchObject({
        helloHadAuth: false,
        helloHadPid: false,
        helloHadUid: false,
        cancelCount: 0
      });
      expect(diagnostics).toContain("fake bridge ready");
      expect(bridge.isConnected()).toBe(true);
    } finally {
      await bridge.close();
    }
    expect(bridge.isConnected()).toBe(false);
  });

  it("propagates AbortSignal cancellation to the exact native request", async () => {
    const bridge = new BridgeProcessClient({ executablePath: fixture, requestTimeoutMs: 2_000 });
    try {
      await bridge.call("status", {});
      const controller = new AbortController();
      const pending = bridge.call("action", { kind: "delay" }, { signal: controller.signal });
      setTimeout(() => controller.abort(), 20);
      await expect(pending).rejects.toMatchObject({ name: "AbortError" });
      const status = (await bridge.call("status", {})) as Record<string, unknown>;
      expect(status.cancelCount).toBe(1);
    } finally {
      await bridge.close();
    }
  });

  it("sends cancel on deadlines and maps native risk challenges", async () => {
    const bridge = new BridgeProcessClient({ executablePath: fixture, requestTimeoutMs: 30 });
    try {
      await expect(bridge.call("action", { kind: "delay" })).rejects.toMatchObject({
        code: "ACTION_TIMEOUT"
      });
      await expect(
        bridge.call("action", { kind: "risk", approvalMode: "native" })
      ).rejects.toBeInstanceOf(NativeApprovalRequiredError);
      await expect(bridge.call("action", { kind: "stale" })).rejects.toMatchObject({
        code: "STALE_FRAME",
        retryable: true
      });
      const status = (await bridge.call("status", {})) as Record<string, unknown>;
      expect(status.cancelCount).toBe(1);
    } finally {
      await bridge.close();
    }
  });

  it("allows human-paced access approval timeouts without widening action deadlines", async () => {
    const bridge = new BridgeProcessClient({ executablePath: fixture });
    try {
      await expect(
        bridge.call("requestAccess", { reason: "Choose a window" }, { timeoutMs: 120_000 })
      ).resolves.toMatchObject({ echoedMethod: "requestAccess" });
      await expect(
        bridge.call("action", { kind: "click" }, { timeoutMs: 30_001 })
      ).rejects.toMatchObject({ code: "BRIDGE_PROTOCOL_ERROR" });
      await expect(
        bridge.call("requestAccess", { reason: "Choose a window" }, { timeoutMs: 300_001 })
      ).rejects.toMatchObject({ code: "BRIDGE_PROTOCOL_ERROR" });
    } finally {
      await bridge.close();
    }
  });

  it("rejects a helper response that exceeds the configured line bound", async () => {
    const bridge = new BridgeProcessClient({
      executablePath: fixture,
      maxLineBytes: 1_024,
      environment: { ...process.env, FAKE_BRIDGE_HUGE: "1" }
    });
    try {
      await expect(bridge.call("status", {})).rejects.toMatchObject({
        code: "BRIDGE_PROTOCOL_ERROR"
      });
    } finally {
      await bridge.close();
    }
  });

  it("rejects an oversized outbound request before writing it", async () => {
    const bridge = new BridgeProcessClient({ executablePath: fixture, maxLineBytes: 1_024 });
    try {
      await bridge.call("status", {});
      await expect(
        bridge.call("action", { kind: "echo", text: "x".repeat(2_000) })
      ).rejects.toMatchObject({ code: "BRIDGE_PROTOCOL_ERROR" });
    } finally {
      await bridge.close();
    }
  });
});
