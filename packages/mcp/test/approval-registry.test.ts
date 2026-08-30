import { describe, expect, it } from "vitest";
import { ApprovalRegistry } from "../src/approval-registry.js";

const args = {
  grant_id: "grant-123456",
  frame_id: "frame-123456",
  intent: "Open the selected item",
  selector: { kind: "point", x: 10, y: 20 },
  timeout_ms: 10_000
};

describe("ApprovalRegistry", () => {
  it("allows only an exact one-shot retry", () => {
    const registry = new ApprovalRegistry(() => Date.parse("2026-01-01T00:00:00Z"));
    const requestId = "approval-request-123456";
    registry.remember("computer_click", args, requestId, "2026-01-01T00:01:00Z");

    expect(() =>
      registry.assertRetry("computer_click", { ...args, approval_request_id: requestId })
    ).not.toThrow();
    expect(() =>
      registry.assertRetry("computer_click", {
        ...args,
        selector: { kind: "point", x: 11, y: 20 },
        approval_request_id: requestId
      })
    ).toThrow(/different action arguments/u);

    registry.consume(requestId);
    expect(() =>
      registry.assertRetry("computer_click", { ...args, approval_request_id: requestId })
    ).toThrow(/already been consumed/u);
  });

  it("rejects expired approval requests", () => {
    let now = Date.parse("2026-01-01T00:00:00Z");
    const registry = new ApprovalRegistry(() => now);
    const requestId = "approval-request-123456";
    registry.remember("computer_click", args, requestId, "2026-01-01T00:00:01Z");
    now += 1_001;
    expect(() =>
      registry.assertRetry("computer_click", { ...args, approval_request_id: requestId })
    ).toThrow(/unknown or expired/u);
  });
});
