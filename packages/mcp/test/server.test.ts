import { createHash } from "node:crypto";
import { realpathSync } from "node:fs";
import { Client } from "@modelcontextprotocol/client";
import { InMemoryTransport } from "@modelcontextprotocol/server";
import { serveStdio } from "@modelcontextprotocol/server/stdio";
import { afterEach, describe, expect, it } from "vitest";
import type { BridgeCallOptions, NativeBridge, NativeMethod } from "../src/bridge/protocol.js";
import { ComputerUseError, NativeApprovalRequiredError } from "../src/errors.js";
import { createComputerUseMcpServer } from "../src/server.js";

const TOOL_NAMES = [
  "computer_get_status",
  "computer_list_displays",
  "computer_list_apps",
  "computer_request_access",
  "computer_release_access",
  "computer_get_state",
  "computer_click",
  "computer_drag",
  "computer_scroll",
  "computer_press_key",
  "computer_type_text",
  "computer_paste",
  "computer_set_value",
  "computer_select_text",
  "computer_perform_secondary_action"
] as const;

const ACTION_NAMES = TOOL_NAMES.slice(6);
const grantId = "grant-123456";
const frameId = "frame-123456";
const approvalRequestId = "approval-request-123456";
const timestamp = "2026-08-29T20:00:00.000Z";
const fixtureBundlePath = realpathSync.native(".");
const otherBundlePath = realpathSync.native("..");

const windowTarget = {
  kind: "window",
  app: {
    bundleId: "com.apple.TextEdit",
    name: "TextEdit",
    pid: 1234,
    bundlePath: fixtureBundlePath
  },
  title: "Document",
  boundsPoints: { x: -100, y: 20, width: 800, height: 600 },
  displayId: "display-123456"
};

function windowAccessResult(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    status: "granted",
    grantId,
    target: windowTarget,
    capabilities: ["observe", "interact"],
    idleExpiresAt: "2099-01-01T00:00:00.000Z",
    sessionOnly: false,
    ...overrides
  };
}

function displayAccessResult(
  displayId = "display-123456",
  overrides: Record<string, unknown> = {}
): Record<string, unknown> {
  return {
    status: "granted",
    grantId,
    target: {
      kind: "display",
      display: {
        displayId,
        name: "External",
        isMain: false,
        isMirrored: false,
        framePoints: { x: -1920, y: 0, width: 1920, height: 1080 },
        pixelWidth: 3840,
        pixelHeight: 2160,
        scaleFactor: 2
      }
    },
    capabilities: ["observe", "interact"],
    idleExpiresAt: "2099-01-01T00:00:00.000Z",
    sessionOnly: true,
    ...overrides
  };
}

function makePng(width: number, height: number): Buffer {
  const png = Buffer.alloc(24);
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]).copy(png);
  Buffer.from("IHDR", "ascii").copy(png, 12);
  png.writeUInt32BE(width, 16);
  png.writeUInt32BE(height, 20);
  return png;
}

const coordinateSpace = {
  widthPx: 200,
  heightPx: 100,
  globalBoundsPoints: { x: -1920, y: 0, width: 100, height: 50 },
  imageToGlobal: { a: 0.5, b: 0, c: 0, d: 0.5, tx: -1920, ty: 0 },
  globalToImage: { a: 2, b: 0, c: 0, d: 2, tx: 3840, ty: 0 }
};

const fullAccessibilityState = {
  mode: "full",
  nodes: [
    {
      elementId: "element-0",
      childElementIds: ["element-1"],
      depth: 0,
      role: "AXWindow",
      title: "Document",
      framePoints: { x: -100, y: 20, width: 800, height: 600 },
      focused: true,
      secure: false,
      actions: []
    },
    {
      elementId: "element-1",
      parentElementId: "element-0",
      childElementIds: [],
      depth: 1,
      role: "AXButton",
      label: "Save",
      framePoints: { x: 20, y: 30, width: 80, height: 30 },
      enabled: true,
      focused: false,
      secure: false,
      actions: ["AXPress"]
    }
  ],
  truncated: false
};

class FakeBridge implements NativeBridge {
  public readonly calls: Array<{
    method: NativeMethod;
    params: Record<string, unknown>;
    options?: BridgeCallOptions;
  }> = [];
  public riskChallenge = false;
  public nextError: Error | undefined;
  public closed = false;
  public stateTarget: unknown = windowTarget;
  public accessibilityState: unknown = fullAccessibilityState;
  public omitAccessibility = false;
  public accessResultOverride: unknown;

  public isConnected(): boolean {
    return !this.closed;
  }

  public async close(): Promise<void> {
    this.closed = true;
  }

  public async call(
    method: NativeMethod,
    params: unknown,
    options?: BridgeCallOptions
  ): Promise<unknown> {
    const record = params as Record<string, unknown>;
    this.calls.push({ method, params: record, ...(options === undefined ? {} : { options }) });
    if (this.nextError !== undefined) {
      const error = this.nextError;
      this.nextError = undefined;
      throw error;
    }

    if (method === "status") {
      return {
        status: "ready",
        nativeVersion: "0.1.0-alpha.1",
        platform: "macos",
        appControlEnabled: true,
        permissions: { accessibility: "authorized", screenRecording: "authorized" },
        activeGrants: []
      };
    }
    if (method === "listDisplays") return { displays: [] };
    if (method === "listApps") return { apps: [] };
    if (method === "requestAccess") {
      if (this.accessResultOverride !== undefined) return this.accessResultOverride;
      const target = record.target as Record<string, unknown>;
      if (target.kind === "display") {
        return {
          status: "granted",
          grantId,
          target: {
            kind: "display",
            display: {
              displayId: String(target.displayId),
              name: "External",
              isMain: false,
              isMirrored: false,
              framePoints: { x: -1920, y: 0, width: 1920, height: 1080 },
              pixelWidth: 3840,
              pixelHeight: 2160,
              scaleFactor: 2
            }
          },
          capabilities: record.capabilities,
          idleExpiresAt: "2099-01-01T00:00:00.000Z",
          sessionOnly: true
        };
      }
      return {
        status: "granted",
        grantId,
        target: windowTarget,
        capabilities: record.capabilities,
        idleExpiresAt: "2099-01-01T00:00:00.000Z",
        sessionOnly: false
      };
    }
    if (method === "releaseAccess") {
      return { status: "released", grantId: String(record.grantId) };
    }
    if (method === "getState") {
      const png = makePng(200, 100);
      return {
        status: "completed",
        grantId,
        target: this.stateTarget,
        frameId,
        capturedAt: timestamp,
        coordinateSpace,
        ...(record.includeAccessibility === false || this.omitAccessibility
          ? {}
          : { accessibility: this.accessibilityState }),
        screenshot: {
          mimeType: "image/png",
          data: png.toString("base64"),
          width: 200,
          height: 100,
          sha256: createHash("sha256").update(png).digest("hex"),
          transform: coordinateSpace
        }
      };
    }
    if (method === "approveRisk") {
      return {
        approvalRequestId: String(record.approvalRequestId),
        disposition: record.approved === true ? "approved" : "denied",
        consumed: false
      };
    }
    if (method === "action") {
      if (this.riskChallenge && record.approvalRequestId === undefined) {
        throw new NativeApprovalRequiredError("Confirm this exact action", {
          approvalRequestId,
          riskTier: "high",
          expiresAt: "2099-01-01T00:00:00.000Z",
          approvalMode: record.approvalMode as "elicitation" | "native"
        });
      }
      return {
        status: "completed",
        actionId: "action-123456",
        grantId,
        target: windowTarget,
        completedAt: timestamp
      };
    }
    return { status: "ok" };
  }
}

type Harness = {
  client: Client;
  bridge: FakeBridge;
  server: { close(): Promise<void> };
};

const harnesses: Harness[] = [];

async function connectHarness(options: {
  era?: "legacy" | "modern";
  bridge?: FakeBridge;
  confirm?: boolean;
  approvalMode?: "auto" | "native";
} = {}): Promise<Harness> {
  const era = options.era ?? "legacy";
  const bridge = options.bridge ?? new FakeBridge();
  const client = new Client(
    { name: "test-client", version: "1.0.0" },
    era === "modern"
      ? {
          capabilities: { elicitation: { form: {} } },
          versionNegotiation: { mode: { pin: "2026-07-28" } },
          inputRequired: { maxRounds: 2 }
        }
      : undefined
  );
  if (era === "modern") {
    client.setRequestHandler("elicitation/create", async () => ({
      action: "accept",
      content: { confirm: options.confirm ?? true }
    }));
  }
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  let server: { close(): Promise<void> };
  if (era === "modern") {
    server = serveStdio(
      context =>
        createComputerUseMcpServer({
          bridge,
          era: context.era,
          ...(options.approvalMode === undefined
            ? {}
            : { approvalMode: options.approvalMode })
        }),
      { transport: serverTransport }
    );
  } else {
    const directServer = createComputerUseMcpServer({
      bridge,
      era,
      ...(options.approvalMode === undefined ? {} : { approvalMode: options.approvalMode })
    });
    await directServer.connect(serverTransport);
    server = directServer;
  }
  await client.connect(clientTransport);
  const harness = { client, bridge, server };
  harnesses.push(harness);
  return harness;
}

afterEach(async () => {
  for (const harness of harnesses.splice(0)) {
    await harness.client.close();
    await harness.server.close();
  }
});

function clickArguments(extra: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    grant_id: grantId,
    frame_id: frameId,
    intent: "Click the visible Save control",
    selector: { kind: "point", x: 20, y: 30 },
    ...extra
  };
}

describe("Computer Use MCP server", () => {
  it("registers exactly 15 tools with conservative action annotations", async () => {
    const { client } = await connectHarness();
    const { tools } = await client.listTools();
    expect(tools.map(tool => tool.name)).toEqual(TOOL_NAMES);
    for (const tool of tools) {
      expect(tool.inputSchema).toMatchObject({ type: "object" });
      expect(tool.outputSchema).toBeDefined();
    }
    for (const name of ACTION_NAMES) {
      const tool = tools.find(candidate => candidate.name === name);
      expect(tool?.annotations).toMatchObject({
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true
      });
    }
    expect(tools.find(tool => tool.name === "computer_get_state")?.annotations).toMatchObject({
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: false
    });
  });

  it("returns structured content and a compact JSON text fallback", async () => {
    const { client } = await connectHarness();
    const result = await client.callTool({ name: "computer_get_status", arguments: {} });
    expect(result.structuredContent).toMatchObject({
      ok: true,
      status: "ready",
      server_version: "0.1.0-alpha.1"
    });
    const text = result.content.find(block => block.type === "text");
    expect(text?.type === "text" ? JSON.parse(text.text) : undefined).toEqual(
      result.structuredContent
    );
  });

  it("returns a PNG resource with exact mixed-scale transforms and readable TTL content", async () => {
    const { client } = await connectHarness();
    const result = await client.callTool({
      name: "computer_get_state",
      arguments: { grant_id: grantId, screenshot: "resource" }
    });
    const structured = result.structuredContent as {
      coordinate_space: { global_bounds_points: { x: number } };
      image: { resource_uri: string; expires_at: string; mime_type: string };
    };
    expect(structured.coordinate_space.global_bounds_points.x).toBe(-1920);
    expect(structured.image.mime_type).toBe("image/png");
    expect(Date.parse(structured.image.expires_at)).toBeGreaterThan(Date.now());
    const resource = await client.readResource({ uri: structured.image.resource_uri });
    expect(resource.contents[0]).toMatchObject({ mimeType: "image/png" });
    expect("blob" in (resource.contents[0] ?? {})).toBe(true);
  });

  it("returns a bounded structured accessibility tree without the legacy text projection", async () => {
    const { client } = await connectHarness();
    const result = await client.callTool({
      name: "computer_get_state",
      arguments: { grant_id: grantId, screenshot: "none" }
    });
    expect(result.structuredContent).toMatchObject({
      ok: true,
      status: "completed",
      accessibility: {
        mode: "full",
        truncated: false,
        nodes: [
          { element_id: "element-0", role: "AXWindow", child_element_ids: ["element-1"] },
          {
            element_id: "element-1",
            parent_element_id: "element-0",
            role: "AXButton",
            secure: false
          }
        ]
      }
    });
    expect((result.structuredContent as { accessibility: object }).accessibility).not.toHaveProperty(
      "text"
    );
  });

  it("accepts only a deterministic diff bound to the requested prior frame", async () => {
    const bridge = new FakeBridge();
    const priorFrameID = "frame-prior-123456";
    bridge.accessibilityState = {
      mode: "diff",
      baseFrameId: priorFrameID,
      upsertedNodes: [
        {
          elementId: "element-2",
          parentElementId: "element-0",
          childElementIds: [],
          depth: 1,
          role: "AXStaticText",
          value: "Saved",
          focused: false,
          secure: false,
          actions: []
        }
      ],
      removedElementIds: ["element-1"],
      truncated: false
    };
    const { client } = await connectHarness({ bridge });
    const result = await client.callTool({
      name: "computer_get_state",
      arguments: {
        grant_id: grantId,
        since_frame_id: priorFrameID,
        screenshot: "none"
      }
    });
    expect(result.structuredContent).toMatchObject({
      ok: true,
      accessibility: {
        mode: "diff",
        base_frame_id: priorFrameID,
        removed_element_ids: ["element-1"]
      }
    });
    expect(bridge.calls.find(call => call.method === "getState")?.params.sinceFrameId).toBe(
      priorFrameID
    );

    bridge.accessibilityState = {
      ...fullAccessibilityState,
      resetReason: "diff_unavailable"
    };
    const reset = await client.callTool({
      name: "computer_get_state",
      arguments: {
        grant_id: grantId,
        since_frame_id: priorFrameID,
        screenshot: "none"
      }
    });
    expect(reset.structuredContent).toMatchObject({
      ok: true,
      accessibility: { mode: "full", reset_reason: "diff_unavailable" }
    });
  });

  it("rejects an unbound diff and an over-budget accessibility result", async () => {
    const bridge = new FakeBridge();
    bridge.accessibilityState = {
      mode: "diff",
      baseFrameId: "frame-wrong-123456",
      upsertedNodes: [],
      removedElementIds: [],
      truncated: false
    };
    const { client } = await connectHarness({ bridge });
    const mismatch = await client.callTool({
      name: "computer_get_state",
      arguments: {
        grant_id: grantId,
        since_frame_id: "frame-prior-123456",
        screenshot: "none"
      }
    });
    expect(mismatch.isError).toBe(true);
    expect(mismatch.structuredContent).toMatchObject({
      ok: false,
      error: { code: "BRIDGE_PROTOCOL_ERROR" }
    });

    bridge.accessibilityState = {
      mode: "full",
      nodes: [
        {
          ...fullAccessibilityState.nodes[0],
          childElementIds: [],
          label: "x".repeat(1_000)
        }
      ],
      truncated: false
    };
    const overBudget = await client.callTool({
      name: "computer_get_state",
      arguments: {
        grant_id: grantId,
        screenshot: "none",
        max_accessibility_chars: 1_000
      }
    });
    expect(overBudget.isError).toBe(true);
    expect(overBudget.structuredContent).toMatchObject({
      ok: false,
      error: { code: "BRIDGE_PROTOCOL_ERROR" }
    });
  });

  it("requires requested accessibility and an explicit reset when a diff falls back to full", async () => {
    const bridge = new FakeBridge();
    bridge.omitAccessibility = true;
    const { client } = await connectHarness({ bridge });
    const omitted = await client.callTool({
      name: "computer_get_state",
      arguments: { grant_id: grantId, screenshot: "none" }
    });
    expect(omitted.isError).toBe(true);
    expect(omitted.structuredContent).toMatchObject({
      ok: false,
      error: { code: "BRIDGE_PROTOCOL_ERROR" }
    });

    bridge.omitAccessibility = false;
    const missingReset = await client.callTool({
      name: "computer_get_state",
      arguments: {
        grant_id: grantId,
        since_frame_id: "frame-prior-123456",
        screenshot: "none"
      }
    });
    expect(missingReset.isError).toBe(true);
    expect(missingReset.structuredContent).toMatchObject({
      ok: false,
      error: { code: "BRIDGE_PROTOCOL_ERROR" }
    });
  });

  it("accepts an explicit empty full accessibility result for a display", async () => {
    const bridge = new FakeBridge();
    bridge.stateTarget = {
      kind: "display",
      display: {
        displayId: "display-123456",
        name: "External",
        isMain: false,
        isMirrored: false,
        framePoints: { x: -1920, y: 0, width: 1920, height: 1080 },
        pixelWidth: 3840,
        pixelHeight: 2160,
        scaleFactor: 2
      }
    };
    bridge.accessibilityState = {
      mode: "full",
      nodes: [],
      truncated: false,
      resetReason: "target_has_no_accessibility_tree"
    };
    const { client } = await connectHarness({ bridge });
    const result = await client.callTool({
      name: "computer_get_state",
      arguments: { grant_id: grantId, screenshot: "none" }
    });
    expect(result.structuredContent).toMatchObject({
      ok: true,
      target: { kind: "display" },
      accessibility: {
        mode: "full",
        nodes: [],
        truncated: false,
        reset_reason: "target_has_no_accessibility_tree"
      }
    });
  });

  it("maps stale-frame native failures to strict tool errors", async () => {
    const bridge = new FakeBridge();
    const { client } = await connectHarness({ bridge });
    bridge.nextError = new ComputerUseError("STALE_FRAME", "Refresh state first.", {
      retryable: true
    });
    const result = await client.callTool({
      name: "computer_click",
      arguments: clickArguments()
    });
    expect(result.isError).toBe(true);
    expect(result.structuredContent).toMatchObject({
      ok: false,
      error: { code: "STALE_FRAME", retryable: true }
    });
  });

  it("uses the native panel and exact one-shot retry for legacy clients", async () => {
    const bridge = new FakeBridge();
    bridge.riskChallenge = true;
    const { client } = await connectHarness({ bridge, era: "legacy" });
    const first = await client.callTool({
      name: "computer_click",
      arguments: clickArguments()
    });
    expect(first.structuredContent).toMatchObject({
      ok: true,
      status: "approval_required",
      approval_request_id: approvalRequestId
    });
    expect(bridge.calls.find(call => call.method === "action")?.params.approvalMode).toBe("native");
    expect(bridge.calls.some(call => call.method === "approveRisk")).toBe(false);

    const mismatch = await client.callTool({
      name: "computer_click",
      arguments: clickArguments({
        click_count: 2,
        approval_request_id: approvalRequestId
      })
    });
    expect(mismatch.structuredContent).toMatchObject({
      ok: false,
      error: { code: "APPROVAL_MISMATCH" }
    });

    const completed = await client.callTool({
      name: "computer_click",
      arguments: clickArguments({ approval_request_id: approvalRequestId })
    });
    expect(completed.structuredContent).toMatchObject({ ok: true, status: "completed" });
    const retry = bridge.calls.filter(call => call.method === "action").at(-1);
    expect(retry?.params.approvalRequestId).toBe(approvalRequestId);

    const replay = await client.callTool({
      name: "computer_click",
      arguments: clickArguments({ approval_request_id: approvalRequestId })
    });
    expect(replay.structuredContent).toMatchObject({
      ok: false,
      error: { code: "APPROVAL_USED" }
    });
  });

  it("uses modern input_required elicitation, resolves once, and executes exact retry", async () => {
    const bridge = new FakeBridge();
    bridge.riskChallenge = true;
    const { client } = await connectHarness({ bridge, era: "modern", confirm: true });
    const completed = await client.callTool({
      name: "computer_click",
      arguments: clickArguments()
    });
    expect(completed.structuredContent).toMatchObject({ ok: true, status: "completed" });
    const actions = bridge.calls.filter(call => call.method === "action");
    const approvals = bridge.calls.filter(call => call.method === "approveRisk");
    expect(actions).toHaveLength(2);
    expect(actions[0]?.params.approvalMode).toBe("elicitation");
    expect(actions[1]?.params.approvalRequestId).toBe(approvalRequestId);
    expect(approvals).toHaveLength(1);
    expect(approvals[0]?.params).toMatchObject({
      approvalRequestId,
      approved: true
    });
  });

  it("can force the one-shot native panel path for a modern elicitation client", async () => {
    const bridge = new FakeBridge();
    bridge.riskChallenge = true;
    const { client } = await connectHarness({
      bridge,
      era: "modern",
      confirm: true,
      approvalMode: "native"
    });
    const first = await client.callTool({
      name: "computer_click",
      arguments: clickArguments()
    });
    expect(first.structuredContent).toMatchObject({
      ok: true,
      status: "approval_required",
      approval_request_id: approvalRequestId
    });
    expect(bridge.calls.find(call => call.method === "action")?.params.approvalMode).toBe("native");
    expect(bridge.calls.some(call => call.method === "approveRisk")).toBe(false);

    const completed = await client.callTool({
      name: "computer_click",
      arguments: clickArguments({ approval_request_id: approvalRequestId })
    });
    expect(completed.structuredContent).toMatchObject({ ok: true, status: "completed" });
  });

  it("resolves a modern elicitation denial without executing the action", async () => {
    const bridge = new FakeBridge();
    bridge.riskChallenge = true;
    const { client } = await connectHarness({ bridge, era: "modern", confirm: false });
    const denied = await client.callTool({
      name: "computer_click",
      arguments: clickArguments()
    });
    expect(denied.structuredContent).toMatchObject({ ok: true, status: "denied" });
    expect(bridge.calls.filter(call => call.method === "action")).toHaveLength(1);
    expect(bridge.calls.filter(call => call.method === "approveRisk")).toHaveLength(1);
    expect(bridge.calls.find(call => call.method === "approveRisk")?.params.approved).toBe(false);
  });

  it("accepts only an exact window grant for the requested app and capability set", async () => {
    const bridge = new FakeBridge();
    bridge.accessResultOverride = windowAccessResult({ capabilities: ["observe"] });
    const { client } = await connectHarness({ bridge });
    const result = await client.callTool({
      name: "computer_request_access",
      arguments: {
        target: {
          kind: "window",
          app: { kind: "name", value: "textedit" },
          launch_if_needed: false
        },
        reason: "Observe the selected document",
        capabilities: ["observe"]
      }
    });
    expect(result.structuredContent).toMatchObject({
      ok: true,
      status: "granted",
      session_only: false,
      capabilities: ["observe"],
      target: {
        kind: "window",
        app: { bundle_id: "com.apple.TextEdit", name: "TextEdit" }
      }
    });

    const pathBridge = new FakeBridge();
    pathBridge.accessResultOverride = windowAccessResult({ capabilities: ["observe"] });
    const { client: pathClient } = await connectHarness({ bridge: pathBridge });
    const pathResult = await pathClient.callTool({
      name: "computer_request_access",
      arguments: {
        target: {
          kind: "window",
          app: { kind: "path", value: fixtureBundlePath },
          launch_if_needed: false
        },
        reason: "Observe the app selected by its canonical path",
        capabilities: ["observe"]
      }
    });
    expect(pathResult.structuredContent).toMatchObject({
      ok: true,
      status: "granted",
      target: { kind: "window", app: { bundle_path: fixtureBundlePath } }
    });
  });

  it("rejects grants that are not exactly bound to the access request", async () => {
    const windowRequest = {
      kind: "window",
      app: { kind: "bundle_id", value: "com.apple.TextEdit" },
      launch_if_needed: false
    } as const;
    const cases: Array<{
      name: string;
      target: Record<string, unknown>;
      capabilities: string[];
      nativeResult: Record<string, unknown>;
    }> = [
      {
        name: "target kind substitution",
        target: windowRequest,
        capabilities: ["observe", "interact"],
        nativeResult: displayAccessResult("display-123456", { sessionOnly: false })
      },
      {
        name: "display substitution",
        target: { kind: "display", display_id: "display-123456" },
        capabilities: ["observe", "interact"],
        nativeResult: displayAccessResult("display-other")
      },
      {
        name: "persistent window grant",
        target: windowRequest,
        capabilities: ["observe", "interact"],
        nativeResult: windowAccessResult({ sessionOnly: true })
      },
      {
        name: "persistent display grant",
        target: { kind: "display", display_id: "display-123456" },
        capabilities: ["observe", "interact"],
        nativeResult: displayAccessResult("display-123456", { sessionOnly: false })
      },
      {
        name: "capability elevation",
        target: windowRequest,
        capabilities: ["observe"],
        nativeResult: windowAccessResult({ capabilities: ["observe", "interact"] })
      },
      {
        name: "capability omission",
        target: windowRequest,
        capabilities: ["observe", "interact"],
        nativeResult: windowAccessResult({ capabilities: ["observe"] })
      },
      {
        name: "duplicate returned capabilities",
        target: windowRequest,
        capabilities: ["observe", "interact"],
        nativeResult: windowAccessResult({ capabilities: ["observe", "interact", "interact"] })
      },
      {
        name: "bundle identifier substitution",
        target: {
          kind: "window",
          app: { kind: "bundle_id", value: "com.example.Other" },
          launch_if_needed: false
        },
        capabilities: ["observe", "interact"],
        nativeResult: windowAccessResult()
      },
      {
        name: "application name substitution",
        target: {
          kind: "window",
          app: { kind: "name", value: "Other" },
          launch_if_needed: false
        },
        capabilities: ["observe", "interact"],
        nativeResult: windowAccessResult()
      },
      {
        name: "application path substitution",
        target: {
          kind: "window",
          app: { kind: "path", value: otherBundlePath },
          launch_if_needed: false
        },
        capabilities: ["observe", "interact"],
        nativeResult: windowAccessResult()
      },
      {
        name: "missing application path metadata",
        target: {
          kind: "window",
          app: { kind: "path", value: fixtureBundlePath },
          launch_if_needed: false
        },
        capabilities: ["observe", "interact"],
        nativeResult: windowAccessResult({
          target: {
            ...windowTarget,
            app: { bundleId: "com.apple.TextEdit", name: "TextEdit", pid: 1234 }
          }
        })
      }
    ];

    for (const testCase of cases) {
      const bridge = new FakeBridge();
      bridge.accessResultOverride = testCase.nativeResult;
      const { client } = await connectHarness({ bridge });
      const result = await client.callTool({
        name: "computer_request_access",
        arguments: {
          target: testCase.target,
          reason: `Reject ${testCase.name}`,
          capabilities: testCase.capabilities
        }
      });
      expect(result.structuredContent, testCase.name).toMatchObject({
        ok: false,
        error: { code: "BRIDGE_PROTOCOL_ERROR" }
      });
    }
  });

  it("makes display grants session-only", async () => {
    const { client, bridge } = await connectHarness();
    const result = await client.callTool({
      name: "computer_request_access",
      arguments: {
        target: { kind: "display", display_id: "display-123456" },
        reason: "Observe the selected display"
      }
    });
    expect(result.structuredContent).toMatchObject({
      ok: true,
      status: "granted",
      grant_id: grantId,
      session_only: true,
      target: { kind: "display" }
    });
    const request = bridge.calls.find(call => call.method === "requestAccess");
    expect(request?.params.timeoutMs).toBe(120_000);
    expect(request?.options?.timeoutMs).toBe(120_000);
  });
});
