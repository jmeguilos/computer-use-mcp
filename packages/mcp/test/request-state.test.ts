import { describe, expect, it } from "vitest";
import { RequestStateCodec } from "../src/request-state.js";

const baseState = {
  tool_name: "computer_click",
  canonical_arguments: '{"frame_id":"frame-123456"}',
  grant_id: "grant-123456",
  frame_id: "frame-123456",
  approval_request_id: "approval-request-123456",
  expires_at: "2027-01-01T00:00:00.000Z"
};

describe("RequestStateCodec", () => {
  it("round-trips an integrity-protected approval binding", () => {
    const codec = new RequestStateCodec({ secret: Buffer.alloc(32, 7), now: () => 1_700_000_000_000 });
    const encoded = codec.mint(baseState);
    const decoded = codec.verify(encoded);

    expect(decoded).toMatchObject(baseState);
    expect(decoded.nonce).toMatch(/^[0-9a-f-]{36}$/u);
    expect(() =>
      codec.assertBound(decoded, {
        toolName: baseState.tool_name,
        canonicalArguments: baseState.canonical_arguments,
        grantId: baseState.grant_id,
        frameId: baseState.frame_id
      })
    ).not.toThrow();
  });

  it("rejects tampering, expiry, and cross-action replay", () => {
    let now = Date.parse("2026-12-31T23:59:59.000Z");
    const codec = new RequestStateCodec({ secret: Buffer.alloc(32, 9), now: () => now });
    const encoded = codec.mint(baseState);
    const [payload, signature] = encoded.split(".");
    expect(() => codec.verify(`${payload}x.${signature}`)).toThrow(/signature/u);

    const decoded = codec.verify(encoded);
    expect(() =>
      codec.assertBound(decoded, {
        toolName: "computer_drag",
        canonicalArguments: baseState.canonical_arguments,
        grantId: baseState.grant_id,
        frameId: baseState.frame_id
      })
    ).toThrow(/different action/u);

    now = Date.parse(baseState.expires_at);
    expect(() => codec.verify(encoded)).toThrow(/Expired/u);
  });
});
