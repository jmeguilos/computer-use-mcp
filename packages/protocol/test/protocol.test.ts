import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";

import {
  ACTION_TOOL_NAMES,
  AccessTargetSchema,
  ALL_NATIVE_METHODS,
  AuthenticatedRequestSchema,
  BridgeRequestSchema,
  BridgeResponseSchema,
  CancelRequestSchema,
  CapabilitiesSchema,
  CoordinateTransformSchema,
  CurrentProtocolVersionSchema,
  HelloRequestSchema,
  HelloResultSchema,
  INSPECTION_TOOL_NAMES,
  MAX_INLINE_PNG_BYTES,
  MAX_WIRE_LINE_BYTES,
  NATIVE_CAPABILITIES,
  NATIVE_METHODS,
  OpaqueIdSchema,
  PROTOCOL_VERSION,
  PUBLIC_CAPABILITIES,
  TOOL_ANNOTATIONS,
  TOOL_NAMES,
  canonicalJson,
  constantTimeEqual,
  sha256Hex
} from "../src/index.js";

async function fixture(name: string): Promise<unknown> {
  const fixtureUrl = new URL(`../fixtures/${name}`, import.meta.url);
  return JSON.parse(await readFile(fixtureUrl, "utf8")) as unknown;
}

const authenticatedEnvelope = {
  protocol: PROTOCOL_VERSION,
  id: "request-test-0001",
  connectionId: "11111111-1111-4111-8111-111111111111",
  connectionToken: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
  deadlineUnixMs: 4_102_444_800_000,
  params: {}
};

describe("public MCP contract", () => {
  it("publishes the exact tool and capability surfaces", () => {
    expect(TOOL_NAMES).toHaveLength(15);
    expect(new Set(TOOL_NAMES).size).toBe(TOOL_NAMES.length);
    expect(TOOL_NAMES.every((name) => name.startsWith("computer_"))).toBe(true);
    expect(PUBLIC_CAPABILITIES).toEqual(["observe", "interact", "clipboard_write"]);
    expect(MAX_INLINE_PNG_BYTES).toBe(5 * 1024 * 1024);
  });

  it("marks all inspection tools read-only and closed-world", () => {
    for (const toolName of INSPECTION_TOOL_NAMES) {
      expect(TOOL_ANNOTATIONS[toolName]).toEqual({
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
      });
    }
  });

  it("marks every input operation conservatively destructive and open-world", () => {
    expect(ACTION_TOOL_NAMES).toHaveLength(9);
    for (const toolName of ACTION_TOOL_NAMES) {
      expect(TOOL_ANNOTATIONS[toolName]).toEqual({
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true
      });
    }
  });

  it("enforces unique, cumulative public capabilities", () => {
    expect(CapabilitiesSchema.parse(["observe", "interact"]))
      .toEqual(["observe", "interact"]);
    expect(() => CapabilitiesSchema.parse(["observe", "observe", "interact"])).toThrow();
    expect(() => CapabilitiesSchema.parse(["interact"])).toThrow();
    expect(() => CapabilitiesSchema.parse(["observe", "clipboard_write"])).toThrow();
    expect(() => CapabilitiesSchema.parse(["admin"])).toThrow();
  });

  it("parses the authoritative discriminated app selector fixture", async () => {
    const value = await fixture("public-window-target-v1.json");
    const target = AccessTargetSchema.parse(value);
    expect(target).toEqual(value);
    expect(target.kind).toBe("window");
    if (target.kind === "window") expect(target.app.kind).toBe("bundle_id");
    expect(() => AccessTargetSchema.parse({
      kind: "window",
      app: "com.example.LegacyString",
      launch_if_needed: false
    })).toThrow();
    expect(() => AccessTargetSchema.parse({
      kind: "window",
      app: { kind: "path", value: "relative/Example.app" },
      launch_if_needed: false
    })).toThrow();
  });

  it("accepts bounded native opaque identifiers such as display-1 and element-0", () => {
    expect(OpaqueIdSchema.parse("display-1")).toBe("display-1");
    expect(OpaqueIdSchema.parse("element-0")).toBe("element-0");
    expect(() => OpaqueIdSchema.parse("short")).toThrow();
  });
});

describe("native JSONL contract", () => {
  it("uses native protocol 1.0 and the 8 MiB line bound", () => {
    expect(Object.isFrozen(PROTOCOL_VERSION)).toBe(true);
    expect(CurrentProtocolVersionSchema.parse(PROTOCOL_VERSION)).toEqual({ major: 1, minor: 0 });
    expect(MAX_WIRE_LINE_BYTES).toBe(8 * 1024 * 1024);
  });

  it("admits same-major minor negotiation while rejecting another major", () => {
    expect(AuthenticatedRequestSchema.parse({
      ...authenticatedEnvelope,
      protocol: { major: 1, minor: 2 },
      method: "status"
    }).protocol.minor).toBe(2);
    expect(() => AuthenticatedRequestSchema.parse({
      ...authenticatedEnvelope,
      protocol: { major: 2, minor: 0 },
      method: "status"
    })).toThrow();
  });

  it("publishes hello plus every and only post-handshake method", () => {
    expect(ALL_NATIVE_METHODS).toEqual([
      "hello",
      "status",
      "listDisplays",
      "listApps",
      "requestAccess",
      "releaseAccess",
      "getState",
      "action",
      "approveRisk",
      "stop",
      "cancel"
    ]);
    expect(NATIVE_METHODS).not.toContain("disconnect");
    expect(NATIVE_CAPABILITIES).toHaveLength(9);
  });

  it("parses the authenticated hello fixture and rejects post-hello authority", async () => {
    const value = await fixture("bridge-hello-v1.json");
    expect(HelloRequestSchema.parse(value).method).toBe("hello");
    expect(BridgeRequestSchema.parse(value)).toEqual(value);
    expect(() => HelloRequestSchema.parse({
      ...(value as Record<string, unknown>),
      connectionId: authenticatedEnvelope.connectionId
    })).toThrow();
  });

  it("parses a camelCase authenticated request fixture", async () => {
    const value = await fixture("bridge-request-v1.json");
    const parsed = AuthenticatedRequestSchema.parse(value);
    expect(parsed.method).toBe("status");
    expect(parsed.connectionId).toBe(authenticatedEnvelope.connectionId);
    expect(BridgeRequestSchema.parse(value)).toEqual(value);
  });

  it("requires connection capability and an absolute deadline after hello", () => {
    const { connectionToken: _token, ...withoutToken } = authenticatedEnvelope;
    const { deadlineUnixMs: _deadline, ...withoutDeadline } = authenticatedEnvelope;
    expect(() => AuthenticatedRequestSchema.parse({ ...withoutToken, method: "status" })).toThrow();
    expect(() => AuthenticatedRequestSchema.parse({ ...withoutDeadline, method: "status" })).toThrow();
  });

  it("accepts every native method and rejects unknown or snake_case envelopes", () => {
    for (const method of NATIVE_METHODS) {
      const params = method === "cancel" ? { requestId: "request-test-0002" } : {};
      expect(AuthenticatedRequestSchema.parse({ ...authenticatedEnvelope, method, params }).method)
        .toBe(method);
    }
    expect(() => AuthenticatedRequestSchema.parse({ ...authenticatedEnvelope, method: "disconnect" })).toThrow();
    expect(() => AuthenticatedRequestSchema.parse({
      protocol: PROTOCOL_VERSION,
      id: "request-test-0001",
      method: "status",
      connection_id: authenticatedEnvelope.connectionId,
      connection_token: authenticatedEnvelope.connectionToken,
      deadline_unix_ms: authenticatedEnvelope.deadlineUnixMs,
      params: {}
    })).toThrow();
  });

  it("binds cancel to one exact outstanding request ID", async () => {
    const value = await fixture("bridge-cancel-v1.json");
    expect(CancelRequestSchema.parse(value).params.requestId).toBe("request-action-0001");
    expect(() => AuthenticatedRequestSchema.parse({
      ...value as Record<string, unknown>,
      params: { requestId: "request-action-0001", all: true }
    })).toThrow();
  });

  it("strictly rejects unknown envelope fields", () => {
    expect(() => AuthenticatedRequestSchema.parse({
      ...authenticatedEnvelope,
      method: "status",
      unexpected: true
    })).toThrow();
  });

  it("parses success and structured error response fixtures", async () => {
    const success = BridgeResponseSchema.parse(await fixture("bridge-response-success-v1.json"));
    expect(success.ok).toBe(true);
    if (success.ok) {
      expect(HelloResultSchema.parse(success.result).acceptedCapabilities)
        .toEqual(["inventory.read", "window.capture"]);
    }
    const failure = BridgeResponseSchema.parse(await fixture("bridge-response-error-v1.json"));
    expect(failure.ok).toBe(false);
    if (!failure.ok) expect(failure.error.code).toBe("approval_required");
  });
});

describe("coordinate transforms", () => {
  it("parses exact camelCase inverse affines across a negative display origin", async () => {
    const transform = CoordinateTransformSchema.parse(
      await fixture("coordinate-transform-negative-origin-v1.json")
    );
    const imagePoint = { x: 12, y: 34 };
    const globalPoint = {
      x: transform.imageToGlobal.a * imagePoint.x + transform.imageToGlobal.c * imagePoint.y + transform.imageToGlobal.tx,
      y: transform.imageToGlobal.b * imagePoint.x + transform.imageToGlobal.d * imagePoint.y + transform.imageToGlobal.ty
    };
    expect(globalPoint).toEqual({ x: -1896, y: -112 });
    expect({
      x: transform.globalToImage.a * globalPoint.x + transform.globalToImage.c * globalPoint.y + transform.globalToImage.tx,
      y: transform.globalToImage.b * globalPoint.x + transform.globalToImage.d * globalPoint.y + transform.globalToImage.ty
    }).toEqual(imagePoint);
  });

  it("rejects a transform whose declared inverse is wrong", async () => {
    const value = await fixture("coordinate-transform-negative-origin-v1.json") as {
      globalToImage: { tx: number };
    } & Record<string, unknown>;
    value.globalToImage.tx += 1;
    expect(() => CoordinateTransformSchema.parse(value)).toThrow(/inverse affine transforms/);
  });
});

describe("canonical approval binding", () => {
  it("canonicalizes approval-bound arguments deterministically", () => {
    const left = { z: 1, a: { d: true, c: "x" } };
    const right = { a: { c: "x", d: true }, z: 1 };
    expect(canonicalJson(left)).toBe(canonicalJson(right));
    expect(sha256Hex(left)).toBe(sha256Hex(right));
  });

  it("keeps canonical hashing identical to the checked-in cross-runtime vector", async () => {
    const value = await fixture("canonical-hash-v1.json") as {
      input: unknown;
      canonical_json: string;
      sha256: string;
    };
    expect(canonicalJson(value.input)).toBe(value.canonical_json);
    expect(sha256Hex(value.input)).toBe(value.sha256);
  });

  it("rejects non-finite values and compares secrets without prefix acceptance", () => {
    expect(() => canonicalJson({ value: Number.POSITIVE_INFINITY })).toThrow();
    expect(constantTimeEqual("same", "same")).toBe(true);
    expect(constantTimeEqual("same", "same-prefix")).toBe(false);
  });
});
