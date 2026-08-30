import { describe, expect, it } from "vitest";

import {
  ErrorCodeSchema as SharedErrorCodeSchema,
  HelloResultSchema as SharedHelloResultSchema,
  MAX_WIRE_LINE_BYTES,
  NATIVE_CAPABILITIES as SHARED_NATIVE_CAPABILITIES,
  NATIVE_METHODS,
  PROTOCOL_VERSION
} from "../../protocol/src/index.js";
import {
  HelloResultSchema,
  NATIVE_CAPABILITIES,
  NATIVE_MAX_LINE_BYTES,
  NATIVE_PROTOCOL,
  NativeMethodSchema,
  WireResponseSchema
} from "../src/bridge/protocol.js";
import { ToolErrorCodeSchema } from "../src/errors.js";

const hello = {
  connectionId: "11111111-1111-4111-8111-111111111111",
  connectionToken: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
  acceptedCapabilities: ["inventory.read", "window.capture"],
  idleExpiresAt: "2026-08-30T12:00:00.000Z"
} as const;

describe("standalone adapter/shared protocol parity", () => {
  it("keeps protocol, line bound, methods, and capabilities exact", () => {
    expect(NATIVE_PROTOCOL).toEqual(PROTOCOL_VERSION);
    expect(NATIVE_MAX_LINE_BYTES).toBe(MAX_WIRE_LINE_BYTES);
    expect(NativeMethodSchema.options).toEqual(NATIVE_METHODS);
    expect(NATIVE_CAPABILITIES).toEqual(SHARED_NATIVE_CAPABILITIES);
  });

  it("keeps every stable MCP-facing error code exact", () => {
    expect(ToolErrorCodeSchema.options).toEqual(SharedErrorCodeSchema.options);
  });

  it("enforces the same connection capability bounds", () => {
    expect(HelloResultSchema.parse(hello)).toEqual(SharedHelloResultSchema.parse(hello));

    for (const invalid of [
      { ...hello, connectionId: "not-a-uuid" },
      { ...hello, connectionToken: "too-short" },
      { ...hello, acceptedCapabilities: ["ambient.authority"] }
    ]) {
      expect(HelloResultSchema.safeParse(invalid).success).toBe(false);
      expect(SharedHelloResultSchema.safeParse(invalid).success).toBe(false);
    }
  });

  it("accepts forward-compatible structured error details at the wire boundary", () => {
    expect(WireResponseSchema.parse({
      protocol: PROTOCOL_VERSION,
      id: "request-1",
      ok: false,
      error: {
        code: "future_native_error",
        message: "A future native error with structured context",
        retryable: false,
        details: { field: "value" }
      }
    }).ok).toBe(false);
  });
});
