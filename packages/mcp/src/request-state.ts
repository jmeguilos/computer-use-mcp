import { createHmac, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import * as z from "zod/v4";
import { ComputerUseError } from "./errors.js";

const ApprovalRequestStateSchema = z
  .object({
    version: z.literal(1),
    tool_name: z.string().min(1).max(128),
    canonical_arguments: z.string().min(2),
    grant_id: z.string().min(8).max(256),
    frame_id: z.string().min(8).max(256),
    approval_request_id: z.string().min(16).max(512),
    expires_at: z.string().datetime({ offset: true }),
    nonce: z.string().uuid()
  })
  .strict();

export type ApprovalRequestState = z.infer<typeof ApprovalRequestStateSchema>;

export class RequestStateCodec {
  readonly #secret: Buffer;
  readonly #now: () => number;

  public constructor(options: { secret?: Uint8Array; now?: () => number } = {}) {
    this.#secret = Buffer.from(options.secret ?? randomBytes(32));
    if (this.#secret.byteLength < 32) throw new Error("Request-state secrets must be at least 32 bytes.");
    this.#now = options.now ?? Date.now;
  }

  public mint(state: Omit<ApprovalRequestState, "version" | "nonce">): string {
    const payload = Buffer.from(
      JSON.stringify({ version: 1, ...state, nonce: randomUUID() }),
      "utf8"
    ).toString("base64url");
    return `${payload}.${this.#sign(payload)}`;
  }

  public verify(encoded: string): ApprovalRequestState {
    const [payload, suppliedSignature, extra] = encoded.split(".");
    if (payload === undefined || suppliedSignature === undefined || extra !== undefined) {
      throw new Error("Malformed request state");
    }
    const expected = Buffer.from(this.#sign(payload), "base64url");
    const supplied = Buffer.from(suppliedSignature, "base64url");
    if (expected.byteLength !== supplied.byteLength || !timingSafeEqual(expected, supplied)) {
      throw new Error("Invalid request-state signature");
    }

    let decoded: unknown;
    try {
      decoded = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
    } catch {
      throw new Error("Invalid request-state payload");
    }
    const state = ApprovalRequestStateSchema.parse(decoded);
    if (Date.parse(state.expires_at) <= this.#now()) throw new Error("Expired request state");
    return state;
  }

  public assertBound(
    state: ApprovalRequestState,
    expected: {
      toolName: string;
      canonicalArguments: string;
      grantId: string;
      frameId: string;
    }
  ): void {
    if (
      state.tool_name !== expected.toolName ||
      state.canonical_arguments !== expected.canonicalArguments ||
      state.grant_id !== expected.grantId ||
      state.frame_id !== expected.frameId
    ) {
      throw new ComputerUseError(
        "APPROVAL_MISMATCH",
        "The elicitation state is bound to a different action, grant, or frame."
      );
    }
  }

  #sign(payload: string): string {
    return createHmac("sha256", this.#secret).update(payload).digest("base64url");
  }
}
