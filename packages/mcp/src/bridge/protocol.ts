import * as z from "zod/v4";

export const NATIVE_PROTOCOL = Object.freeze({ major: 1, minor: 0 });
export const NATIVE_MAX_LINE_BYTES = 8 * 1024 * 1024;

export const NativeMethodSchema = z.enum([
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

export type NativeMethod = z.infer<typeof NativeMethodSchema>;

export const NATIVE_CAPABILITIES = Object.freeze([
  "inventory.read",
  "window.capture",
  "display.capture",
  "accessibility.read",
  "accessibility.action",
  "input.synthetic",
  "indicator.control",
  "risk.approve",
  "session.stop"
] as const);

const WireProtocolSchema = z
  .object({ major: z.literal(1), minor: z.number().int().min(0) })
  .strict();

export const WireResponseSchema = z.discriminatedUnion("ok", [
  z
    .object({
      protocol: WireProtocolSchema,
      id: z.string().min(1).max(256),
      ok: z.literal(true),
      result: z.unknown()
    })
    .strict(),
  z
    .object({
      protocol: WireProtocolSchema,
      id: z.string().min(1).max(256),
      ok: z.literal(false),
      error: z
        .object({
          code: z.string().min(1).max(128),
          message: z.string().min(1).max(4_000),
          retryable: z.boolean(),
          details: z
            .object({
              approvalRequestId: z.string().min(16).max(512),
              riskTier: z.string().min(1).max(128),
              expiresAt: z.string().datetime({ offset: true }),
              approvalMode: z.enum(["elicitation", "native"])
            })
            .strict()
            .optional()
        })
        .strict()
    })
    .strict()
]);

export const HelloResultSchema = z
  .object({
    connectionId: z.string().min(8).max(256),
    connectionToken: z.string().min(16).max(512),
    acceptedCapabilities: z.array(z.string().min(1).max(128)),
    idleExpiresAt: z.string().datetime({ offset: true })
  })
  .strict();

export type BridgeCallOptions = {
  signal?: AbortSignal;
  timeoutMs?: number;
};

export interface NativeBridge {
  call(method: NativeMethod, params: unknown, options?: BridgeCallOptions): Promise<unknown>;
  close(): Promise<void>;
  isConnected(): boolean;
}
