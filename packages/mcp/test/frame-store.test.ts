import { describe, expect, it, vi } from "vitest";
import { FrameStore } from "../src/frame-store.js";

describe("FrameStore", () => {
  it("expires PNG resources after the configured TTL", () => {
    let now = 1_800_000_000_000;
    const store = new FrameStore({ ttlMs: 60_000, now: () => now });
    const frame = store.put({
      frameId: "frame-123456",
      data: Buffer.from("png").toString("base64"),
      mimeType: "image/png",
      width: 1,
      height: 1,
      sha256: "a".repeat(64)
    });

    expect(store.get(frame.frameId)).toEqual(frame);
    expect(store.uri(frame.frameId)).toBe("computer-use://frame/frame-123456");
    now += 60_000;
    expect(store.get(frame.frameId)).toBeUndefined();
  });

  it("enforces the decoded-byte ceiling", () => {
    const store = new FrameStore();
    expect(() =>
      store.put({
        frameId: "frame-too-large",
        data: Buffer.alloc(5 * 1024 * 1024 + 1).toString("base64"),
        mimeType: "image/png",
        width: 1,
        height: 1,
        sha256: "b".repeat(64)
      })
    ).toThrow(/exceeds the 5242880-byte resource limit/u);
  });

  it("bounds aggregate screenshot memory and evicts oldest resources", () => {
    const store = new FrameStore({
      maxDecodedBytes: 8,
      maxTotalDecodedBytes: 12,
      maxEntries: 2
    });
    const put = (frameId: string): void => {
      store.put({
        frameId,
        data: Buffer.alloc(6).toString("base64"),
        mimeType: "image/png",
        width: 1,
        height: 1,
        sha256: frameId.padEnd(64, "c").slice(0, 64)
      });
    };

    put("frame-oldest");
    put("frame-middle");
    put("frame-newest");

    expect(store.get("frame-oldest")).toBeUndefined();
    expect(store.get("frame-middle")).toBeDefined();
    expect(store.get("frame-newest")).toBeDefined();
  });

  it("removes expired screenshot bytes without a subsequent lookup", () => {
    vi.useFakeTimers();
    const store = new FrameStore({ ttlMs: 10, maxDecodedBytes: 8, maxTotalDecodedBytes: 8 });
    try {
      store.put({
        frameId: "frame-expiring",
        data: Buffer.alloc(8).toString("base64"),
        mimeType: "image/png",
        width: 1,
        height: 1,
        sha256: "d".repeat(64)
      });

      vi.advanceTimersByTime(10);
      expect(store.get("frame-expiring")).toBeUndefined();
    } finally {
      vi.useRealTimers();
    }
  });
});
