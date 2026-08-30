import { ComputerUseError } from "./errors.js";

export type StoredFrame = {
  frameId: string;
  data: string;
  mimeType: "image/png";
  width: number;
  height: number;
  sha256: string;
  expiresAt: string;
};

type FrameStoreOptions = {
  ttlMs?: number;
  maxDecodedBytes?: number;
  maxEntries?: number;
  maxTotalDecodedBytes?: number;
  now?: () => number;
};

type FrameEntry = {
  frame: StoredFrame;
  decodedBytes: number;
  expiryTimer: ReturnType<typeof setTimeout>;
};

export class FrameStore {
  readonly #frames = new Map<string, FrameEntry>();
  readonly #ttlMs: number;
  readonly #maxDecodedBytes: number;
  readonly #maxEntries: number;
  readonly #maxTotalDecodedBytes: number;
  readonly #now: () => number;
  #totalDecodedBytes = 0;

  public constructor(options: FrameStoreOptions = {}) {
    this.#ttlMs = options.ttlMs ?? 60_000;
    this.#maxDecodedBytes = options.maxDecodedBytes ?? 5 * 1024 * 1024;
    this.#maxEntries = options.maxEntries ?? 16;
    this.#maxTotalDecodedBytes = options.maxTotalDecodedBytes ?? 20 * 1024 * 1024;
    this.#now = options.now ?? Date.now;
    if (
      this.#ttlMs <= 0 ||
      this.#maxDecodedBytes <= 0 ||
      this.#maxEntries <= 0 ||
      this.#maxTotalDecodedBytes < this.#maxDecodedBytes
    ) {
      throw new RangeError("FrameStore limits must be positive and internally consistent.");
    }
  }

  public put(frame: Omit<StoredFrame, "expiresAt">): StoredFrame {
    this.#pruneExpired();
    const decodedBytes = Buffer.byteLength(frame.data, "base64");
    if (decodedBytes > this.#maxDecodedBytes) {
      throw new ComputerUseError(
        "SCREEN_CAPTURE_FAILED",
        `The screenshot exceeds the ${this.#maxDecodedBytes}-byte resource limit.`,
        { remediation: "Request a smaller max_width_px value." }
      );
    }

    const stored = {
      ...frame,
      expiresAt: new Date(this.#now() + this.#ttlMs).toISOString()
    };
    this.#delete(frame.frameId);
    while (
      this.#frames.size >= this.#maxEntries ||
      this.#totalDecodedBytes + decodedBytes > this.#maxTotalDecodedBytes
    ) {
      const oldest = this.#frames.keys().next().value as string | undefined;
      if (oldest === undefined) break;
      this.#delete(oldest);
    }

    const expiryTimer = setTimeout(() => this.#delete(frame.frameId), this.#ttlMs);
    expiryTimer.unref?.();
    this.#frames.set(frame.frameId, { frame: stored, decodedBytes, expiryTimer });
    this.#totalDecodedBytes += decodedBytes;
    return stored;
  }

  public get(frameId: string): StoredFrame | undefined {
    const entry = this.#frames.get(frameId);
    if (entry === undefined) return undefined;
    if (Date.parse(entry.frame.expiresAt) <= this.#now()) {
      this.#delete(frameId);
      return undefined;
    }
    return entry.frame;
  }

  public uri(frameId: string): string {
    return `computer-use://frame/${encodeURIComponent(frameId)}`;
  }

  #pruneExpired(): void {
    for (const [frameId, entry] of this.#frames) {
      if (Date.parse(entry.frame.expiresAt) <= this.#now()) this.#delete(frameId);
    }
  }

  #delete(frameId: string): void {
    const entry = this.#frames.get(frameId);
    if (entry === undefined) return;
    clearTimeout(entry.expiryTimer);
    this.#totalDecodedBytes -= entry.decodedBytes;
    this.#frames.delete(frameId);
  }
}
